# frozen_string_literal: true

class DtextLinkPolicy < ApplicationPolicy
  def permitted_search_params
    super + %i[link_target model_type model_id has_linked_wiki has_linked_tag wiki_page_title tag_name]
  end
end
