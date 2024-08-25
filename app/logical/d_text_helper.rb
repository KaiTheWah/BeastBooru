# frozen_string_literal: true

module DTextHelper
  module_function

  def parse(text, **)
    DText.parse(text, **)
  end

  def format_text(text, **)
    data = preprocess([text])
    parse(text, **) => { dtext: html }
    html = postprocess(html, *data)
    html
  end

  def preprocess(dtext_messages)
    names = dtext_messages.map { |message| parse_wiki_titles(message) }.flatten.uniq
    wiki_pages = WikiPage.where(title: names)
    tags = Tag.where(name: names)
    artists = Artist.where(name: names)

    [wiki_pages, tags, artists]
  end

  def postprocess(html, wiki_pages, tags, artists)
    fragment = parse_html(html)

    fragment.css("a.dtext-wiki-link").each do |node| # rubocop:disable Metrics/BlockLength
      path = Addressable::URI.parse(node["href"]).path
      name = path[%r{\A/wiki_pages/(.*)\z}i, 1]
      name = CGI.unescape(name)
      name = WikiPage.normalize_title(name)
      wiki = wiki_pages.find { |w| w.title == name }
      tag = tags.find { |t| t.name == name }
      artist = artists.find { |a| a.name == name }

      if tag.present?
        node["class"] += " tag-type-#{tag.category}"
      end

      if tag.present? && tag.artist?
        node["href"] = "/artists/show_or_new?name=#{CGI.escape(name)}"

        if artist.blank?
          node["class"] += " dtext-artist-does-not-exist"
          node["title"] = "This artist page does not exist"
        end
      else
        if wiki.blank?
          node["class"] += " dtext-wiki-does-not-exist"
          node["title"] = "This wiki page does not exist"
        end

        if WikiPage.is_meta_wiki?(name)
          # skip (meta wikis aren't expected to have a tag)
        elsif tag.blank?
          node["class"] += " dtext-tag-does-not-exist"
          node["title"] = "This wiki page does not have a tag"
        elsif tag.empty?
          node["class"] += " dtext-tag-empty"
          node["title"] = "This wiki page does not have a tag"
        end
      end
    end

    fragment.to_s
  end

  def parse_wiki_titles(text)
    return [] if text.blank?
    parse(text) => { dtext: html }
    fragment = parse_html(html)

    titles = fragment.css("a.dtext-wiki-link").map do |node|
      if node["href"].include?("show_or_new")
        title = node["href"][%r{\A/wiki_pages/show_or_new\?title=(.*)\z}i, 1]
      else
        title = node["href"][%r{\A/wiki_pages/(.*)\z}i, 1]
      end
      title = CGI.unescape(title)
      title = WikiPage.normalize_title(title)
      title
    end

    titles.uniq
  end

  def parse_external_links(text)
    return [] if text.blank?
    parse(text) => { dtext: html }
    fragment = parse_html(html)

    links = fragment.css("a.dtext-external-link").pluck("href")
    links.uniq
  end

  def dtext_links_differ?(old, new)
    Set.new(parse_wiki_titles(old)) != Set.new(parse_wiki_titles(new)) ||
      Set.new(parse_external_links(old)) != Set.new(parse_external_links(new))
  end

  def parse_html(html)
    Nokogiri::HTML5.fragment(html, max_tree_depth: -1)
  end

  # Rewrite wiki links to [[old_name]] with [[new_name]]. We attempt to match
  # the capitalization of the old tag when rewriting it to the new tag, but if
  # we can't determine how the new tag should be capitalized based on some
  # simple heuristics, then we skip rewriting the tag.
  # @param dtext [String] the DText input
  # @param old_name [String] the old wiki name
  # @param new_name [String] the new wiki name
  # @return [String] the DText output
  def rewrite_wiki_links(dtext, old_name, new_name)
    old_name = old_name.downcase.squeeze("_").tr("_", " ").strip
    new_name = new_name.downcase.squeeze("_").tr("_", " ").strip

    # Match `[[name]]` or `[[name|title]]`
    dtext.gsub(/\[\[(.*?)(?:\|(.*?))?\]\]/) do |match|
      name = $1
      title = $2

      # Skip this link if it isn't the tag we're trying to replace.
      normalized_name = name.downcase.tr("_", " ").squeeze(" ").strip
      next match if normalized_name != old_name

      # Strip qualifiers, e.g. `atago (midsummer march) (azur lane)` => `atago`
      unqualified_name = name.tr("_", " ").squeeze(" ").strip.gsub(/( \(.*\))+\z/, "")

      # If old tag was lowercase, e.g. [[ink tank (Splatoon)]], then keep new tag in lowercase.
      if unqualified_name == unqualified_name.downcase
        final_name = new_name
        # If old tag was capitalized, e.g. [[Colored pencil (medium)]], then capitialize new tag.
      elsif unqualified_name == unqualified_name.downcase.capitalize
        final_name = new_name.capitalize
        # If old tag was in titlecase, e.g. [[Hatsune Miku (cosplay)]], then titlecase new tag.
      elsif unqualified_name == unqualified_name.split.map(&:capitalize).join(" ")
        final_name = new_name.split.map(&:capitalize).join(" ")
        # If we can't determine how to capitalize the new tag, then keep the old tag.
        # e.g. [[Suzumiya Haruhi no Yuuutsu]] -> [[The Melancholy of Haruhi Suzumiya]]
      else
        next match
      end

      if title.present?
        "[[#{final_name}|#{title}]]"
        # If the new name has a qualifier, then hide the qualifier in the link.
      elsif final_name.match?(/( \(.*\))+\z/)
        "[[#{final_name}|]]"
      else
        "[[#{final_name}]]"
      end
    end
  end
end
