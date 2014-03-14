module Cardboard
  class Page < ActiveRecord::Base
    has_one :url_object, class_name: "Cardboard::Url", :as => :urlable, :autosave => true
    has_many :parts, class_name: "Cardboard::PagePart", :dependent => :destroy, :validate => true

    belongs_to :template, class_name: "Cardboard::Template"
      
    attr_accessor :parent_url, :is_root


    def url_object_with_auto_build
      build_url_object unless url_object_without_auto_build
      url_object_without_auto_build #to continue the association chain
    end
    alias_method_chain :url_object, :auto_build

    accepts_nested_attributes_for :url_object
    accepts_nested_attributes_for :parts, allow_destroy: true, :reject_if => :all_blank
    # TODO: allow destroy and allow all blank only if repeatable

  
    before_validation :default_values

    include RankedModel
    ranks :position

    #validations
    # validates_associated :parts
    validates :title, :template, presence:true
    validates :identifier, uniqueness: {:case_sensitive => false}, :format => { :with => /\A[a-z\_0-9]+\z/,
                           :message => "Only downcase letters, numbers and underscores are allowed" }, presence: true

    #scopes
    scope :preordered, -> {joins(:url_object).order("cardboard_urls.path ASC, position ASC, cardboard_urls.slug ASC")} 
    scope :with_path,  -> (p) {joins(:url_object).where("cardboard_urls.path = ?",p) }


    #delegates
    delegate :slug, :path, :slug=, :path=, :using_slug_backup?, to: :url_object, allow_nil: true

    #class variables
    after_commit do
      Page.clear_arranged_pages
    end

    #overwritten setters/getters

    def is_root=(val)
      self.position_position = :first if val
    end


    def meta_seo=(hash)
      self.url_object.title = hash[:title]
      self.url_object.description = hash[:description]
    end
    def meta_seo
      {
        title: url_object.title,
        description: url_object.description
      }
    end

    def url
      url_object.to_s
    end


    #class methods
    def self.find_by_url(full_url)
      Cardboard::Url.urlable_for(full_url, type: self.name)
    end

    def self.root
      #TODO: check that join work correctly
      with_path('/').rank(:position).first
    end
    def self.homepage; self.root; end

    def root?
      @root_id ||= Page.root.id
      @root_id == self.id
    end

    #instance methods


    def template_hash
      @template_hash ||= self.template.fields
    end

    # @page.get("slideshow.image1")
    # @page.get("slideshow").first.image1
    # @page.get("slideshow").each...

    # slideshow = @page.get("slideshow")
    # slideshow.field("image1")
    # slideshow.each{|p| p.field("image")}
    # slideshow.get("slide1")
    def get(field)
      f = field.split(".")
      parts = self.parts.where(identifier: f.first)

      if template_hash[f.first.to_sym][:repeatable]
        raise "Part is repeatable, expected each loop" unless f.size == 1 
        parts
      else
        part = parts.first
        return nil unless part
        f.size == 1 ? part : part.attr(f.last)
      end
    end


    # SEO
    # children inherit their parent's SEO settings (these can be overwritten)
    def seo
      @_seo ||= begin
        seo = self.meta_seo
        seo = self.parent.seo.merge(seo) if parent
        seo = Page.root.seo.merge(seo) unless root?
        seo
      end
    end
    
    def seo=(hash)
      # to hash is important here for strong parameters
      self.meta_seo = hash.to_hash
      @_seo = nil
    end

    def split_path
      path[1..-1].split("/")
    end

    def parent
      @parent ||= Cardboard::Page.find_by_url(path)
    end

    # Get all other pages
    def parent_url_options
      # @parent_url_options ||= begin
        Cardboard::Page.all.inject(["/"]) do |result, elm| 
          result << elm.url unless elm.id == self.id
          result
        end.sort
      # end
    end

    def parent_url
      return "/" if parent.nil?
      parent.url
    end

    def parent=(new_parent)
      return nil if new_parent && !new_parent.is_a?(Cardboard::Page) 
      self.path = new_parent ? new_parent.url : "/"
    end

    def parent_id=(new_parent_id)
      self.parent = Cardboard::Page.where(identifier: new_parent_id).first
    end

    def parent_url=(new_parent_url)
      self.parent = Cardboard::Page.find_by_url(new_parent_url)
    end

    def children
      Cardboard::Page.with_path(url)
    end

    def siblings
      Cardboard::Page.with_path(path).where("cardboard_pages.id != ?", id)
    end

    def depth
      # root is depth 0
      split_path.size
    end

    # Arrange array of nodes into a nested hash of the form 
    # {node => children}, where children = {} if the node has no children
    #
    # Example:
    # {#<Cardboard::Page => {
    #    #<Cardboard::Page => {}
    #    #<Cardboard::Page => {}
    #    #<Cardboard::Page => {#<Cardboard::Page => {}}
    # }}
    def self.arrange(root_page = nil)
      root_page ||= self.root
      return unless root_page
      # TODO: use root_page...

      Rails.cache.fetch("arranged_pages") do
        pages = self.preordered

        pages.inject(ActiveSupport::OrderedHash.new) do |ordered_hash, page|
          (["/"] + page.split_path).inject(ordered_hash) do |insertion_hash, subpath|
            
            insertion_hash.each do |parent, children|
              insertion_hash = children if subpath == parent.slug
            end
            insertion_hash
          end[page] = ActiveSupport::OrderedHash.new
          ordered_hash
        end
      end
    end 
    def self.clear_arranged_pages
      # clear cache when a page changes
      Rails.cache.delete("arranged_pages")
    end

  private

    def default_values
      self.title ||= self.identifier.try(:parameterize, "_")
      self.path ||=  "/"
      self.slug ||= self.title.try(:to_url)
    end
  end
end
