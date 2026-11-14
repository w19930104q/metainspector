require 'spec_helper'

describe 'Offline documents' do
  let(:archive_html) { fixture_file('offline_archive.html') }
  let(:archive_with_base_html) { fixture_file('offline_archive_with_base.html') }

  describe 'a document archived after a redirect' do
    let(:doc) do
      MetaInspector.new('http://example.com/original',
                        document: archive_html,
                        final_url: 'http://example.com/articles/archived',
                        status: 200,
                        response_headers: { 'Content-Type' => 'text/html; charset=utf-8',
                                            'X-Archived-At' => 'yesterday' })
    end

    it 'uses the final url as the document url' do
      expect(doc.url).to eq('http://example.com/articles/archived')
    end

    it 'resolves canonicals, links, images and iframes against the final url' do
      expect(doc.canonicals.first[:href]).to eq('http://example.com/articles/archived-page')
      expect(doc.links.internal).to eq(['http://example.com/about'])
      expect(doc.images.to_a).to eq(['http://example.com/articles/images/photo.jpg'])
      expect(doc.iframe_sources).to eq(['http://example.com/embed/video'])
    end

    it 'exposes the given status, headers and content type' do
      expect(doc.response.status).to eq(200)
      expect(doc.response.headers).to eq('content-type' => 'text/html; charset=utf-8',
                                         'x-archived-at' => 'yesterday')
      expect(doc.content_type).to eq('text/html')
    end

    it 'builds to_hash without any request' do
      hash = doc.to_hash

      expect(hash['url']).to eq('http://example.com/articles/archived')
      expect(hash['title']).to eq('Archived Page')
      expect(hash['content_type']).to eq('text/html')
      expect(hash['response']).to eq('status' => 200,
                                     'headers' => { 'content-type' => 'text/html; charset=utf-8',
                                                    'x-archived-at' => 'yesterday' })
      expect(hash['images']).to eq(['http://example.com/articles/images/photo.jpg'])
      expect(hash['iframes'].first[:src]).to eq('/embed/video')
      expect(a_request(:any, /.*/)).not_to have_been_made
    end
  end

  describe 'relative addresses with a base tag' do
    let(:doc) do
      MetaInspector.new('http://example.com/original',
                        document: archive_with_base_html,
                        final_url: 'http://example.com/final/page')
    end

    it 'resolves canonicals, links, images and iframes against the base href' do
      expect(doc.canonicals.first[:href]).to eq('http://cdn.example.com/archive/canonical-page')
      expect(doc.links.all).to eq(['http://cdn.example.com/archive/page2'])
      expect(doc.images.to_a).to eq(['http://cdn.example.com/archive/img/pic.png'])
      expect(doc.iframe_sources).to eq(['http://cdn.example.com/archive/embed/player'])
    end
  end

  describe 'non-HTML declarations' do
    it 'raises NonHtmlError when the content_type option declares non-HTML content' do
      expect do
        MetaInspector.new('http://example.com/', document: archive_html, content_type: 'application/pdf')
      end.to raise_error(MetaInspector::NonHtmlError, /application\/pdf/)
    end

    it 'raises NonHtmlError when the response headers declare non-HTML content' do
      expect do
        MetaInspector.new('http://example.com/', document: archive_html,
                                                 response_headers: { 'Content-Type' => 'application/pdf' })
      end.to raise_error(MetaInspector::NonHtmlError, /application\/pdf/)
    end

    it 'parses the document when non-HTML content is allowed' do
      doc = MetaInspector.new('http://example.com/', document: archive_html,
                                                     content_type: 'application/pdf',
                                                     allow_non_html_content: true)

      expect(doc.content_type).to eq('application/pdf')
      expect(doc.to_hash['content_type']).to eq('application/pdf')
      expect(doc.title).to eq('Archived Page')
    end
  end

  describe 'parse-only mode' do
    let(:doc) { MetaInspector.new('http://offline-archive.example/archived', document: archive_html) }

    it 'makes no request at all' do
      doc.to_hash

      expect(a_request(:any, /.*/)).not_to have_been_made
    end

    it 'keeps the old defaults for missing response data' do
      expect(doc.content_type).to be_nil
      expect(doc.response.status).to be_nil
      expect(doc.response.headers).to eq({})

      hash = doc.to_hash
      expect(hash['content_type']).to be_nil
      expect(hash['response']).to eq('status' => nil, 'headers' => {})
    end

    it 'resolves relative addresses against the document url' do
      expect(doc.links.internal).to eq(['http://offline-archive.example/about'])
      expect(doc.images.to_a).to eq(['http://offline-archive.example/images/photo.jpg'])
      expect(doc.iframe_sources).to eq(['http://offline-archive.example/embed/video'])
    end

    it 'downloads images only when image downloading is enabled' do
      stub = stub_request(:get, 'http://offline-archive.example/images/photo.jpg')
             .to_return(fixture_file('100x100.jpg.response'))

      no_downloads = MetaInspector.new('http://offline-archive.example/archived',
                                       document: archive_html, download_images: false)
      expect(no_downloads.images.with_size)
        .to eq([['http://offline-archive.example/images/photo.jpg', 0, 0]])
      expect(stub).not_to have_been_requested

      downloading = MetaInspector.new('http://offline-archive.example/archived',
                                      document: archive_html)
      expect(downloading.images.with_size)
        .to eq([['http://offline-archive.example/images/photo.jpg', 100, 100]])
      expect(stub).to have_been_requested
    end
  end

  describe 'option validation' do
    it 'rejects a non-integer status' do
      expect do
        MetaInspector.new('http://example.com/', document: archive_html, status: '200')
      end.to raise_error(ArgumentError, 'status must be an Integer or nil')
    end

    it 'rejects non-hash response headers' do
      expect do
        MetaInspector.new('http://example.com/', document: archive_html, response_headers: 'Content-Type: text/html')
      end.to raise_error(ArgumentError, 'response_headers must be a Hash or nil')
    end

    it 'rejects offline response options without a document' do
      expect do
        MetaInspector.new('http://example.com/', status: 200)
      end.to raise_error(ArgumentError, 'status can only be used with the document option')

      expect do
        MetaInspector.new('http://example.com/', final_url: 'http://example.com/other')
      end.to raise_error(ArgumentError, 'final_url can only be used with the document option')
    end
  end
end
