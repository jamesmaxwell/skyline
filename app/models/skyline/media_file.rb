# @private
class Skyline::MediaFile < Skyline::MediaNode      
  include Skyline::Taggable

  after_create :store_data
  after_destroy :remove_data, :reset_ref_object
  validates_presence_of :data, :on => :create
  validates_uniqueness_of :name, :scope => "parent_id"
  
  default_scope :order => :name
  
  attr_accessible :name, :data
  
  def self.set_missing_file_types
    self.all(:conditions => "file_type = '' OR file_type IS NULL").each do |media_file|
      media_file.set_file_type!
    end
    true
  end
  
  # returns thumbnail of image
  # ==== Parameters
  # width<Integer>:: required width of the thumbnail
  # height<Integer>:: required height of the thumbnail
  #
  # ==== Returns
  # <ImageBlob>:: blob of the Magick::Image  
  def thumbnail(width=100,height=100)
    img = Magick::Image::read(self.file_path).first
    
    width,height = self.proportional_dimension(width,height,img.columns,img.rows)
    
    stream = img.change_geometry!("#{width}x#{height}"){ |c,r,i| i.resize!(c,r) }
    stream.to_blob        
  end

  # returns the dimension of the original image
  #
  # ==== Returns
  # <Hash>:: hash of width and height attributes
  def dimension
    return nil if self.file_type != "image"
    {"width" => self.width, "height" => self.height}
  end
  
  # Calculate the proportional dimension of this media file
  # this method will never go beyond the bounds of org_w and org_h.
  # 
  # @param width [Integer] The target width of this calculation
  # @param height [Integer] The target height of this calculation
  # @param org_w [Integer] The original width
  # @param org_h [Integer] The origin height
  #
  # @return Array<Integer,Integer> The new width and height
  def proportional_dimension(width,height,org_w = self.width, org_h = self.height)
    return nil if org_w.blank? && org_h.blank?

    # Make sure we don't go beyond the actual size!
    if (width.to_i > org_w || height.to_i > org_h) 
      width = [width.to_i, org_w].min
      height = [height.to_i, org_h].min
    end
    
    w_factor = width.to_f / org_w.to_f
    h_factor = height.to_f / org_h.to_f
    factor = case 
      when w_factor == 0 then h_factor
      when h_factor == 0 then w_factor
      else [w_factor, h_factor].min
    end
    
    [(org_w*factor).round, (org_h*factor).round]
  end
  
  # sanitize filename and set correct mime-type for IO object of file data
  #
  # ==== Parameters
  # data<IO>:: IO object with file data
  #
  # ==== Returns
  # data<IO>:: IO object with sanitized filename and correct mime-type
  def data=(data)
    unless data.size == 0
      @data = data
      self.name = sanitize_filename(@data.original_filename)
      
      # Fix the mime types
      @data.content_type = MIME::Types.type_for(@data.original_filename).to_s
      self.content_type = @data.content_type.downcase.gsub(/[^a-z\-\/]/,"")
      self.file_type = self.determine_file_type
      
      self.set_dimensions
      self.size = @data.size
    end
    @data
  end

  def data
    @data
  end
  
  # The URL of the file
  # Uses Rails.application.routes to generate the URL
  #
  # @param size [String] The size to use for the filename  
  #
  # @options options [Boolean] :cms Wether or not this is an internal URL (default=false)
  def url(size=nil, options={})
    options.reverse_merge! :cms => false
    
    url_options = {
      
      :action => "show",
      :file_id => self.id.to_s,
      :name => self.name,
      :only_path => true
    }
    
    url_options[:size] = size if size
    
    if(options[:cms])
      url_options.update({
        :controller => "skyline/media/data",
        :dir_id => self.parent_id.to_s
      })
      
      Skyline::Engine.routes.url_for(url_options)
    else
      url_options.update({
        :controller => "skyline/site/media_files_data",  
        :cache_key => self.cache_key 
      })
      Rails.application.routes.url_for(url_options)
    end
  end
  
  
  # The key to use for caching, currently uses the 
  # updated_at, reversed and padded to six 0's
  #
  # @return [String]
  def cache_key
    s = self.updated_at.to_i.to_s.ljust(6,"0").reverse
    [s[0,2], s[2,2], s[4..-1]].join("/")
  end
  
  # Regex to check the size parameter
  SIZE_REGEX = /\A\d+x\d+\Z/
  
  def valid_size?(raw_size)
    raw_size =~ SIZE_REGEX
  end
  
  # Normalizes the size parameter
  #
  # @param size [String] A string with the format "AAAxBBB" where AAA and BBB are numbers.
  # @return [nil,false,Array[width,height]] Nil if no sizing should be done, false if this is just wrong and an array with [w,h] if it's ok.
  def normalize_size(raw_size)
    return nil unless raw_size.present?
    if valid_size?(raw_size)
      size = raw_size.to_s.split("x").map{|v| v.to_i }
    
      # Unless all the sizes are set we have to assume this is crap and return an :unprocessable_entity 
      if !size.all?{|s| s > 0 }
        return false
      end    
    
      # Never upscale images disproportionally
      if size[0] == self.width && size[1] >= self.height || size[1] == self.height && size[0] >= self.width
        return nil
      end
    else
      return false
    end
    size
  end
  
  
  def determine_file_type
    lookup = Mime::Type.lookup(self.content_type)
    lookup.instance_variable_get("@symbol").to_s
  end
  
  def set_file_type!
    file_type = determine_file_type
    self.update_attribute(:file_type, file_type) unless file_type.blank?
  end
      
  protected
  
  def set_dimensions
    return if self.file_type != "image"
    begin
      img = case self.data
      when ActionDispatch::Http::UploadedFile,Tempfile
        Magick::Image::read(self.data.path).first
      else
        Magick::Image::from_blob(self.data.read).first
        self.data.rewind        
      end
      
      self.width = img.columns
      self.height = img.rows
    rescue
    end
  end
  
  
  # Write data to disk
  def store_data
    return unless self.data.present?
    
    if !self.data.respond_to?(:to_str) && self.data.respond_to?(:each)
      File.open(self.file_path, "wb+"){|f| self.data.each{|d| f.write(d) } }
      self.data.close if self.data.respond_to?(:close)
    else
      File.open(self.file_path, "wb+"){|f| f.write(self.data) }
    end
  end
  
  # Remove data from disk
  def remove_data
    File.unlink(self.file_path) if File.exist?(self.file_path)
  end 
  
  # reset ref objects that refer to removed media file
  # by setting referable_id = nil
  def reset_ref_object
    Skyline::RefObject.update_all({:referable_id => nil}, {:referable_id => self.id, :referable_type => self.class.name})    
  end
end
