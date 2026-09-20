namespace :help_docs do
  desc "Regenerate db/default_en_help_files/*.textile from app/views/help's English HTML — the source stays the HTML, this is a one-way extraction. Usage: bin/rails help_docs:extract_textile_help_text"
  task extract_textile_help_text: :environment do
    require "nokogiri"

    docs = {
      "easy_manual" => "app/views/help/easy_manual_en.html.erb",
      "pro_manual"  => "app/views/help/pro_manual_en.html.erb",
      "legal"       => "app/views/help/legal_en.html.erb",
      "terms"       => "app/views/help/_terms_text_en.html.erb"
    }

    # ERB becomes either nothing (chrome, the upload form) or a bracket
    # placeholder (site-specific values — see ContactPlaceholders). Order
    # matters: link_to patterns must be handled before the bare CONTACT_* ones
    # they may contain.
    strip_erb = lambda do |text|
      # Layer 3 — the file-upload form. Whole block, never admin content.
      text = text.gsub(/<%=\s*form_with.*?<%\s*end\s*%>/m, "")

      # Layer 3 — the whole EU-declaration download section, heading included:
      # dynamic, depends on whether a document was ever uploaded.
      text = text.gsub(/<%\s*if\s+@eu_declaration\s*%>.*?<%\s*end\s*%>/m, "")
      # Layer 3 — the sudo-only upload section. form_with...end stripped first
      # (above); this takes the remaining if/end wrapper and its own heading.
      text = text.gsub(/<%\s*if\s+current_admin&\.sudo\?\s*%>.*?<%\s*end\s*%>/m, "")

      # Layer 1 — chrome.
      text = text.gsub(/<%=\s*render\s+"help\/back"\s*%>\s*/, "")
      text = text.gsub(/<%\s*content_for\s+:title.*?%>\s*/, "")

      # Internal links with route helpers — anchor dropped, path hardcoded.
      text = text.gsub(/<%=\s*link_to\s+"([^"]*)",\s*easy_manual_path(?:\(anchor:\s*"[^"]*"\))?\s*%>/, '"\1":/easy_manual')
      text = text.gsub(/<%=\s*link_to\s+"([^"]*)",\s*pro_manual_path(?:\(anchor:\s*"[^"]*"\))?\s*%>/, '"\1":/pro_manual')
      text = text.gsub(/<%=\s*link_to\s+"([^"]*)",\s*legal_path(?:\(anchor:\s*"[^"]*"\))?\s*%>/, '"\1":/legal')
      text = text.gsub(/<%=\s*link_to\s+"([^"]*)",\s*legal_url\s*%>/, '"\1":/legal')

      # The service host link and any other literal-URL link_to.
      text = text.gsub(/<%=\s*link_to\s+service_host,\s*"https:\/\/#\{service_host\}"\s*%>/, '"[WEBSITE]":https://[WEBSITE]')
      text = text.gsub(/<%=\s*link_to\s+"([^"]*)",\s*"(#[^"]*|\/[^"]*)"\s*%>/, '"\1":\2')

      # mail_to and bare CONTACT_*/SERVICE_NAME constants.
      text = text.gsub(/<%=\s*mail_to\s+CONTACT_EMAIL\s*%>/, "[EMAIL]")
      text = text.gsub(/<%=\s*CONTACT_EMAIL\s*%>/, "[EMAIL]")
      text = text.gsub(/<%=\s*SERVICE_NAME\s*%>/, "[SERVICE NAME]")
      text = text.gsub(/<%=\s*CONTACT_TRADING\s*%>/, "[TRADING NAME]")
      text = text.gsub(/<%=\s*CONTACT_NAME\s*%>/, "[LEGAL NAME]")
      text = text.gsub(/<%=\s*CONTACT_STREET\s*%>/, "[STREET]")
      text = text.gsub(/<%=\s*CONTACT_CITY\s*%>/, "[CITY]")
      text = text.gsub(/<%=\s*CONTACT_COUNTRY\s*%>/, "[COUNTRY]")

      text
    end

    inline_to_textile = nil
    inline_to_textile = lambda do |node|
      node.children.map { |child|
        case child
        when Nokogiri::XML::Text
          child.text
        when Nokogiri::XML::Element
          case child.name
          when "strong", "b" then "*#{inline_to_textile.call(child)}*"
          when "em", "i" then "_#{inline_to_textile.call(child)}_"
          when "a"
            href = child["href"].to_s
            "\"#{inline_to_textile.call(child)}\":#{href}"
          when "br" then "\n"
          else inline_to_textile.call(child)
          end
        else
          ""
        end
      }.join
    end

    walk_block = nil
    walk_block = lambda do |node, lines|
      case node.name
      when "nav"
        nil # TOC — dropped, regenerated at render time
      when /\Ah[1-6]\z/
        level = node.name[1]
        lines << "h#{level}. #{inline_to_textile.call(node).strip}"
      when "p"
        text = inline_to_textile.call(node).strip
        lines << text unless text.empty?
      when "ul", "ol"
        marker = node.name == "ul" ? "*" : "#"
        node.xpath("./li").each do |li|
          lines << "#{marker} #{inline_to_textile.call(li).strip}"
        end
      when "div", "section"
        node.children.each { |c| walk_block.call(c, lines) if c.is_a?(Nokogiri::XML::Element) }
      else
        node.children.each { |c| walk_block.call(c, lines) if c.is_a?(Nokogiri::XML::Element) }
      end
    end

    block_to_textile = lambda do |doc|
      lines = []
      doc.children.each do |node|
        next unless node.is_a?(Nokogiri::XML::Element)
        walk_block.call(node, lines)
      end
      lines.join("\n\n").gsub(/\n{3,}/, "\n\n").strip
    end

    unrecognized = []

    docs.each do |doc_name, path|
      next unless File.exist?(path)

      raw = File.read(path)
      stripped = strip_erb.call(raw)

      leftover = stripped.scan(/<%.*?%>/)
      unrecognized.concat(leftover.map { |l| "#{path}: #{l}" }) if leftover.any?

      fragment = Nokogiri::HTML5.fragment(stripped)
      textile = block_to_textile.call(fragment)

      out_path = Rails.root.join("db", "default_en_help_files", "#{doc_name}.textile")
      File.write(out_path, textile)
      puts "wrote #{out_path} (#{textile.bytesize} bytes)"
    end

    # A hard failure, not a warning. A script bug that silently ships wrong or
    # truncated content into a real published page is worse than a deploy that
    # does not ship at all — and this is what makes it safe to run unattended,
    # at build time, rather than only ever by hand.
    if unrecognized.any?
      abort "\nUNRECOGNIZED ERB LEFT BEHIND — extraction is incomplete, nothing was meant to survive strip_erb unconverted:\n" +
            unrecognized.map { |u| "  #{u}" }.join("\n")
    end

    puts "\nNo leftover ERB. Read the diff before committing — wording and register are not this script's job."
  end
end
