module MetaInspector
  # Stands in for the HTTP response when the document is provided directly
  # with the document option instead of being fetched
  OfflineResponse = Struct.new(:status, :headers)

  # A MetaInspector::Document knows about its URL and its contents
  class Document
    attr_reader :allow_non_html_content, :allow_redirections, :headers

    # Initializes a new instance of MetaInspector::Document, setting the URL
    # Options:
    # * connection_timeout: defaults to 20 seconds
    # * read_timeout: defaults to 20 seconds
    # * retries: defaults to 3 times
    # * allow_redirections: when true, follow HTTP redirects. Defaults to true
    # * head_first: check content type with HEAD before GET. Defaults to false
    # * document: the html of the url as a string
    # * status: the HTTP status of an archived response, only with document.
    #   Defaults to nil
    # * response_headers: a hash with the HTTP headers of an archived response,
    #   only with document. Keys are lowercased. Defaults to {}
    # * content_type: the declared content type of an archived response, only
    #   with document. Defaults to the content-type in response_headers, if any
    # * final_url: the URL an archived response was served from, only with
    #   document. Relative links, images, canonicals and iframes resolve
    #   against it. Defaults to the url passed as first argument
    # * headers: object containing custom headers for the request
    # * normalize_url: true by default
    # * download_images: fetch missing image dimensions. Defaults to true
    # * max_image_downloads: maximum image size lookups, or nil for unlimited
    # * download_image_options: supports reject_invalid_images (default false)
    # * fetch_all_image_meta: enable image validity metadata (default false)
    # * max_html_bytes: maximum HTML size before parsing, or nil for unlimited
    # * url_filter: callable receiving a URI before each request; false/nil rejects it
    # * faraday_options: an optional hash of options to pass to Faraday on the request.
    #   Its faraday_http_cache key configures response caching with Faraday::HttpCache
    # * faraday_http_cache: deprecated, use faraday_options: { faraday_http_cache: ... }
    def initialize(initial_url, options = {})
      options             = defaults.merge(options)
      max_html_bytes = options[:max_html_bytes]
      unless max_html_bytes.nil? || (max_html_bytes.is_a?(Integer) && max_html_bytes >= 0)
        raise ArgumentError, 'max_html_bytes must be a non-negative Integer or nil'
      end
      @max_image_downloads = options[:max_image_downloads]
      unless @max_image_downloads.nil? || (@max_image_downloads.is_a?(Integer) && @max_image_downloads >= 0)
        raise ArgumentError, 'max_image_downloads must be a non-negative Integer or nil'
      end

      @connection_timeout = options[:connection_timeout]
      @read_timeout       = options[:read_timeout]
      @retries            = options[:retries]
      @encoding           = options[:encoding]

      @allow_redirections     = options[:allow_redirections]
      @allow_non_html_content = options[:allow_non_html_content]

      @document           = options[:document]
      @download_images    = options[:download_images]
      @headers            = options[:headers]
      @normalize_url      = options[:normalize_url]
      @faraday_options    = options[:faraday_options]
      @faraday_http_cache = options[:faraday_http_cache]
      @http_session       = MetaInspector::HttpSession.new(options)

      validate_offline_options!(options)
      @status           = options[:status]
      unless @status.nil? || @status.is_a?(Integer)
        raise ArgumentError, 'status must be an Integer or nil'
      end
      @response_headers = normalize_response_headers(options[:response_headers])
      @content_type     = normalize_content_type(options[:content_type])

      @url                = MetaInspector::URL.new(initial_url, normalize:          @normalize_url)
      @url.url            = options[:final_url] if @document && options[:final_url]
      @request            = MetaInspector::Request.new(@url,    http_session: @http_session,
                                                                allow_redirections: @allow_redirections,
                                                                head_first:         options[:head_first],
                                                                allow_non_html_content: @allow_non_html_content,
                                                                connection_timeout: @connection_timeout,
                                                                read_timeout:       @read_timeout,
                                                                retries:            @retries,
                                                                encoding:           @encoding,
                                                                headers:            @headers,
                                                                faraday_options:    @faraday_options,
                                                                faraday_http_cache: @faraday_http_cache) unless @document
      check_offline_content_type! if @document
      @parser             = MetaInspector::Parser.new(self,     download_images:    @download_images,
                                                                max_html_bytes: max_html_bytes,
                                                                max_image_downloads: @max_image_downloads,
                                                                download_image_options: options[:download_image_options],
                                                                fetch_all_image_meta: options[:fetch_all_image_meta],
                                                                image_downloader: MetaInspector::ImageDownloader.new(@http_session, @url, options))
    end

    extend Forwardable
    delegate [:url, :scheme, :host, :root_url,
              :tracked?, :untracked_url, :untrack!]   => :@url

    delegate [:parsed, :language, :title, :best_title, :author, :best_author,
              :h1, :h2, :h3, :h4, :h5, :h6, :description, :best_description, :links,
              :images, :iframes, :iframe_sources, :feeds, :feed, :charset, :meta_tags,
              :meta_tag, :meta, :favicon,
              :head_links, :stylesheets, :canonicals] => :@parser

    # Returns all document data as a nested Hash
    def to_hash
      {
        'url'              => url,
        'scheme'           => scheme,
        'host'             => host,
        'root_url'         => root_url,
        'language'         => language,
        'title'            => title,
        'best_title'       => best_title,
        'author'           => author,
        'best_author'      => best_author,
        'description'      => description,
        'best_description' => best_description,
        'h1'               => h1,
        'h2'               => h2,
        'h3'               => h3,
        'h4'               => h4,
        'h5'               => h5,
        'h6'               => h6,
        'links'            => links.to_hash,
        'images'           => images.to_a,
        'iframes'          => iframes,
        'charset'          => charset,
        'feeds'            => feeds,
        'content_type'     => content_type,
        'meta_tags'        => meta_tags,
        'favicon'          => images.favicon,
        'response'         => { 'status'  => response.status,
                                'headers' => response.headers }
      }
    end

    # Returns the contents of the document as a string
    def to_s
      document
    end

    # Returns the declared content type of the document. When fetched, it
    # comes from the response headers; when the document is passed directly,
    # from the content_type option or the content-type response header, if any
    def content_type
      return @request.content_type if @request

      @content_type || content_type_from_response_headers
    end

    # Returns the response of the request. When the document is passed
    # directly, returns an offline response built from the status and
    # response_headers options
    def response
      return @request.response if @request

      OfflineResponse.new(@status, @response_headers)
    end

    private

    OFFLINE_ONLY_OPTIONS = %i[status response_headers content_type final_url].freeze

    def validate_offline_options!(options)
      return if options[:document]

      used = OFFLINE_ONLY_OPTIONS.select { |key| options.key?(key) }
      unless used.empty?
        raise ArgumentError, "#{used.join(', ')} can only be used with the document option"
      end
    end

    def normalize_response_headers(headers)
      return {} if headers.nil?
      unless headers.is_a?(Hash)
        raise ArgumentError, 'response_headers must be a Hash or nil'
      end

      headers.each_with_object({}) { |(key, value), result| result[key.to_s.downcase] = value }
    end

    def normalize_content_type(content_type)
      content_type&.to_s&.split(';')&.first&.strip
    end

    def content_type_from_response_headers
      normalize_content_type(@response_headers['content-type'])
    end

    def check_offline_content_type!
      return if allow_non_html_content || content_type.nil? || content_type == 'text/html'

      fail MetaInspector::NonHtmlError.new "The url provided contains #{content_type} content instead of text/html content"
    end

    def defaults
      { :connection_timeout     => 20,
        :read_timeout           => 20,
        :retries                => 3,
        :headers                => {
                                     'User-Agent'      => default_user_agent,
                                     'Accept-Encoding' => 'identity'
                                  },
        :allow_redirections     => true,
        :allow_non_html_content => false,
        :head_first             => false,
        :normalize_url          => true,
        :download_images        => true,
        :max_image_downloads    => nil }
    end

    def default_user_agent
      "MetaInspector/#{MetaInspector::VERSION} (+https://github.com/jaimeiniesta/metainspector)"
    end

    def document
      @document ||= if !allow_non_html_content && !content_type.nil? && content_type != 'text/html'
        fail MetaInspector::NonHtmlError.new "The url provided contains #{content_type} content instead of text/html content"
      else
        @request.read
      end
    end
  end
end
