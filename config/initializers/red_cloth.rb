module RedClothExtensions

  class YouTubeScrubber < Rails::HTML::PermitScrubber
    def initialize
      super()
      self.tags = %w(div p span br hr b strong i em u a ul ol li h1 h2 h3 h4 h5 h6 blockquote pre code img video table tr td th iframe)
      self.attributes = %w(href target src alt title class id width height frameborder allowfullscreen start end list start_radio rel modestbranding allow itemprop itemscope itemtype)
    end

    def scrub_node(node)
      if node.name == 'iframe'
        src = node['src']
        unless src && src.start_with?('https://www.youtube-nocookie.com/embed/')
          node.remove
        end
      end
      super
    end

  end

  def self.clean(text, add_external_targets = false)
    return "" if text.nil?
    
    textile = RedCloth.new(text.to_s)
    textile.no_span_caps = true
    html = textile.to_html
    
    if add_external_targets
      html = html.gsub(/href="(https?:\/\/)/, 'target="_blank" href="\1')
    end
    
    scrubber = YouTubeScrubber.new
    fragment = Loofah.fragment(html)
    fragment.scrub!(scrubber)
    fragment.to_s.html_safe   
  end
  
end

# Use as clean(textarea.text) rather than sanitize(textilize(textarea.text)).
def clean(text, add_external_targets = false)
  RedClothExtensions.clean(text, add_external_targets)
end

# Make it available globally
Object.send(:include, RedClothExtensions)



