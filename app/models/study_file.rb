class StudyFile

  ###
  #
  # StudyFile: class holding metadata about data files either uploaded through the UI or 'synced' from a GCS bucket
  #
  ###

  ###
  #
  # SETTINGS & FIELD DEFINITIONS
  #
  ###

  include Mongoid::Document
  include Mongoid::Timestamps
  include Mongoid::Paperclip
  include Rails.application.routes.url_helpers # for accessing download_file_path and download_private_file_path

  # constants, used for statuses and file types
  STUDY_FILE_TYPES = ['Cluster', 'Expression Matrix', 'Gene List', 'Metadata', 'Fastq', 'Documentation', 'Other']
  PARSEABLE_TYPES = ['Cluster', 'Expression Matrix', 'Gene List', 'Metadata']
  UPLOAD_STATUSES = %w(new uploading uploaded)
  PARSE_STATUSES = %w(unparsed parsing parsed)
  PRIMARY_DATA_EXTENTIONS = %w(fastq fastq.zip fastq.gz fastq.tar.gz fq fq.zip fq.gz fq.tar.gz)

  # associations
  belongs_to :study, index: true
  has_many :cluster_groups, dependent: :destroy
  has_many :expression_scores, dependent: :destroy
  has_many :precomputed_scores, dependent: :destroy
  has_many :study_metadata, dependent: :destroy

  # field definitions
  field :name, type: String
  field :path, type: String
  field :description, type: String
  field :file_type, type: String
  field :status, type: String
  field :parse_status, type: String, default: 'unparsed'
  field :data_dir, type: String
  field :human_fastq_url, type: String
  field :human_data, type: Boolean, default: false
  field :generation, type: String
  field :x_axis_label, type: String, default: ''
  field :y_axis_label, type: String, default: ''
  field :z_axis_label, type: String, default: ''
  field :x_axis_min, type: Integer
  field :x_axis_max, type: Integer
  field :y_axis_min, type: Integer
  field :y_axis_max, type: Integer
  field :z_axis_min, type: Integer
  field :z_axis_max, type: Integer
  field :queued_for_deletion, type: Boolean, default: false
  field :remote_location, type: String, default: ''

  Paperclip.interpolates :data_dir do |attachment, style|
    attachment.instance.data_dir
  end

  ###
  #
  # VALIDATIONS & CALLBACKS
  #
  ###

  # callbacks
  before_validation   :set_file_name_and_data_dir, on: :create
  before_save         :sanitize_name
  after_save          :set_cluster_group_ranges

  has_mongoid_attached_file :upload,
                            :path => ":rails_root/data/:data_dir/:filename",
                            :url => '',
                            :filename_cleaner => Paperclip::FilenameCleaner.new(/[\s&$+,:;=?@<>\[\]\{\}\|\\\^~%# ]/)

  # turning off validation to allow any kind of data file to be uploaded
  do_not_validate_attachment_file_type :upload

  validates_uniqueness_of :upload_file_name, scope: :study_id, unless: Proc.new {|f| f.human_data?}
  validates_presence_of :name

  ###
  #
  # INSTANCE METHODS
  #
  ###

  # return correct path to file based on visibility & type
  def download_path
    if self.upload_file_name.nil?
      self.human_fastq_url
    else
      if self.study.public?
        download_file_path(self.study.url_safe_name, self.download_location)
      else
        download_private_file_path(self.study.url_safe_name, self.download_location)
      end
    end
  end

  # JSON response for jQuery uploader
  def to_jq_upload(error=nil)
    {
        '_id' => self._id,
        'name' => read_attribute(:upload_file_name),
        'size' => read_attribute(:upload_file_size),
        'url' => download_path,
        'delete_url' => delete_study_file_study_path(self.study._id, self._id),
        'delete_type' => "DELETE"
    }
  end

  def parseable?
    PARSEABLE_TYPES.include?(self.file_type)
  end

  def parsed?
    self.parse_status == 'parsed'
  end

  # file type as a css class
  def file_type_class
    self.file_type.downcase.split.join('-') + '-file'
  end

  # return path to a file's 'public data' path (which will be a symlink to data dir)
  def public_data_path
    File.join(self.study.data_public_path, self.upload_file_name)
  end

  # convert all domain ranges from floats to integers
  def convert_all_ranges
    if self.file_type == 'Cluster'
      required_vals = 4
      domain = {
          x_axis_min: self.x_axis_min.to_i == 0 ? nil : self.x_axis_min.to_i,
          x_axis_max: self.x_axis_max.to_i == 0 ? nil : self.x_axis_max.to_i,
          y_axis_min: self.y_axis_min.to_i == 0 ? nil : self.y_axis_min.to_i,
          y_axis_max: self.y_axis_max.to_i == 0 ? nil : self.y_axis_max.to_i
      }
      empty_domain = {
          x_axis_min: nil,
          x_axis_max: nil,
          y_axis_min: nil,
          y_axis_max: nil
      }
      if self.cluster_groups.first.is_3d?
        domain[:z_axis_min] = self.z_axis_min.to_i == 0 ? nil : self.z_axis_min.to_i
        domain[:z_axis_max] = self.z_axis_max.to_i == 0 ? nil : self.z_axis_max.to_i
        empty_domain[:z_axis_min] = nil
        empty_domain[:z_axis_max] = nil
        required_vals = 6
      end
      # need to clear out domain first to force persistence
      self.update(empty_domain)
      if required_vals == domain.values.compact.size
        self.update(domain)
      end
    end
  end

  # for constructing a path to a file in a Google bucket (takes folders into account due to issue with upload_file_name not allowing slashes)
  def download_location
    self.remote_location.blank? ? self.upload_file_name : self.remote_location
  end

  ###
  #
  # CACHING METHODS
  #
  ###

  # helper method to invalidate any matching front-end caches when parsing/deleting a study_file
  def invalidate_cache_by_file_type
    cache_key = self.cache_removal_key
    unless cache_key.nil?
      # clear matching caches in background
      CacheRemovalJob.new(cache_key).delay.perform
    end
  end

  # helper method to return cache removal key based on file type (this is refactored out for use in tests)
  def cache_removal_key
    study_name = self.study.url_safe_name
    case self.file_type
      when 'Cluster'
        name_key = self.name.split.join('-')
        @cache_key = "#{study_name}.*render_cluster.*#{name_key}"
      when 'Expression Matrix'
        @cache_key = "#{study_name}.*expression"
      when 'Gene List'
        name_key = self.name.split.join('-')
        @cache_key = "#{study_name}.*#{name_key}"
      when 'Metadata'
        # when reparsing metadata, almost all caches now become invalid so we just clear all matching the study
        @cache_key =  "#{study_name}"
      else
        @cache_key = nil
    end
    @cache_key
  end

  ###
  #
  # DELETE METHODS
  #
  ###

  # delete all queued study file objects
  def self.delete_queued_files
    study_files = self.where(queued_for_deletion: true)
    study_files.each do |file|
      Rails.logger.info "#{Time.now} deleting queued file #{file.name} in study #{file.study.name}."
      file.destroy
      Rails.logger.info "#{Time.now} #{file.name} successfully deleted."
    end
    true
  end

  private

  ###
  #
  # CUSTOM VALIDATIONS & CALLBACKS
  #
  ###

  # strip whitespace from name if the file is a cluster or gene list (will cause problems when rendering)
  def sanitize_name
    if ['Gene List', 'Cluster'].include?(self.file_type)
      self.name.strip!
    end
  end

  # set filename and construct url safe name from study
  def set_file_name_and_data_dir
    if self.upload_file_name.nil?
      self.status = 'uploaded'
      if self.name.nil?
        self.name = ''
      end
    elsif (self.name.nil? || self.name.blank?) || (!self.new_record? && self.upload_file_name != self.name)
      self.name = self.upload_file_name
    end
    self.data_dir = self.study.data_dir
  end

  # set ranges for cluster_groups if necessary
  def set_cluster_group_ranges
    if self.file_type == 'Cluster' && self.cluster_groups.any?
      cluster = self.cluster_groups.first
      # check if range values are present and set accordingly
      if !self.x_axis_min.nil? && !self.x_axis_max.nil? && !self.y_axis_min.nil? && !self.y_axis_max.nil?
        domain_ranges = {
            x: [self.x_axis_min, self.x_axis_max],
            y: [self.y_axis_min, self.y_axis_max]
        }
        if !self.z_axis_min.nil? && !self.z_axis_max.nil?
          domain_ranges[:z] = [self.z_axis_min, self.z_axis_max]
        end
        cluster.update(domain_ranges: domain_ranges)
      else
        # either user has not supplied ranges or is deleting them, so clear entry for cluster_group
        cluster.update(domain_ranges: nil)
      end
    end
  end
end
