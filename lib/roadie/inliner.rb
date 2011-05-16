require 'set'

module Roadie
  # This class is the core of Roadie as it does all the actual work. You just give it
  # the CSS rules, the HTML and the url_options for rewriting URLs and let it go on
  # doing all the heavy lifting and building.
  class Inliner
    # Regexp matching all the url() declarations in CSS
    #
    # It matches without any quotes and with both single and double quotes
    # inside the parenthesis. There's much room for improvement, of course.
    CSS_URL_REGEXP = %r{
      url\(
        (["']?)
        (
          [^(]*            # Text leading up to before opening parens
          (?:\([^)]*\))*   # Texts containing parens pairs
          [^(]+            # Texts without parens - required
        )
        \1                 # Closing quote
      \)
    }x

    # Initialize a new Inliner with the given CSS, HTML and url_options.
    #
    # @param [String] css
    # @param [String] html
    # @param [Hash] url_options Supported keys: +:host+, +:port+ and +:protocol+
    def initialize(css, html, url_options)
      @css = css
      @inline_css = []
      @html = html
      @url_options = url_options
    end

    # Start the inlining and return the final HTML output
    # @return [String]
    def execute
      adjust_html do |document|
        @document = document
        add_missing_structure
        extract_inline_style_elements
        inline_css_rules
        make_image_urls_absolute
        make_style_urls_absolute
        @document = nil
      end
    end

    private
      attr_reader :css, :html, :url_options, :document

      def inline_css
        @inline_css.join("\n")
      end

      def parsed_css
        CssParser::Parser.new.tap do |parser|
          parser.add_block!(css) if css
          parser.add_block!(inline_css)
        end
      end

      def adjust_html
        Nokogiri::HTML.parse(html).tap do |document|
          yield document
        end.to_html
      end

      def add_missing_structure
        html_node = document.at_css('html')
        html_node['xmlns'] ||= 'http://www.w3.org/1999/xhtml'

        if document.at_css('html > head').present?
          head = document.at_css('html > head')
        else
          head = Nokogiri::XML::Node.new('head', document)
          document.at_css('html').children.before(head)
        end

        unless document.at_css('html > head > meta[http-equiv=Content-Type]')
          meta = Nokogiri::XML::Node.new('meta', document)
          meta['http-equiv'] = 'Content-Type'
          meta['content'] = 'text/html; charset=utf-8'
          head.add_child(meta)
        end
      end

      def extract_inline_style_elements
        document.css("style").each do |style|
          next if style['media'] == 'print' or style['data-immutable']
          @inline_css << style.content
          style.remove
        end
      end

      def inline_css_rules
        elements_with_declarations.each do |element, declarations|
          ordered_declarations = []
          seen_properties = Set.new
          declarations.sort.reverse_each do |declaration|
            next if seen_properties.include?(declaration.property)
            ordered_declarations.unshift(declaration)
            seen_properties << declaration.property
          end

          rules_string = ordered_declarations.map { |declaration| declaration.to_s }.join(';')
          element['style'] = [rules_string, element['style']].compact.join(';')
        end
      end

      def elements_with_declarations
        Hash.new { |hash, key| hash[key] = [] }.tap do |element_declarations|
          parsed_css.each_rule_set do |rule_set|
            each_selector_without_psuedo(rule_set) do |selector, specificity|
              each_element_in_selector(selector) do |element|
                style_declarations_in_rule_set(specificity, rule_set) do |declaration|
                  element_declarations[element] << declaration
                end
              end
            end
          end
        end
      end

      def each_selector_without_psuedo(rules)
        rules.selectors.reject { |selector| selector.include?(':') }.each do |selector|
          yield selector, CssParser.calculate_specificity(selector)
        end
      end

      def each_element_in_selector(selector)
        document.css(selector.strip).each do |element|
          yield element
        end
      end

      def style_declarations_in_rule_set(specificity, rule_set)
        rule_set.each_declaration do |property, value, important|
          yield StyleDeclaration.new(property, value, important, specificity)
        end
      end

      def make_image_urls_absolute
        document.css('img').each do |img|
          img['src'] = ensure_absolute_url(img['src']) if img['src']
        end
      end

      def make_style_urls_absolute
        document.css('*[style]').each do |element|
          styling = element['style']
          element['style'] = styling.gsub(CSS_URL_REGEXP) { "url(#{$1}#{ensure_absolute_url($2, '/stylesheets')}#{$1})" }
        end
      end

      def ensure_absolute_url(url, base_path = nil)
        base, uri = absolute_url_base(base_path), URI.parse(url)
        if uri.relative? and base
          base.merge(uri).to_s
        else
          uri.to_s
        end
      rescue URI::InvalidURIError
        return url
      end

      def absolute_url_base(base_path)
        return nil unless url_options
        port = url_options[:port]
        URI::Generic.build({
          :scheme => url_options[:protocol] || 'http',
          :host => url_options[:host],
          :port => (port ? port.to_i : nil),
          :path => base_path
        })
      end
  end
end