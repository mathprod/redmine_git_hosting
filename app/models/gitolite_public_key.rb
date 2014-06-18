class GitolitePublicKey < ActiveRecord::Base
  unloadable

  TITLE_LENGTH_LIMIT = 255

  STATUS_ACTIVE = true
  STATUS_LOCKED = false

  KEY_TYPE_USER   = 0
  KEY_TYPE_DEPLOY = 1

  DEPLOY_PSEUDO_USER = "deploy_key"

  ## Relations
  belongs_to :user
  has_many   :repository_deployment_credentials, :dependent => :destroy

  ## Validations
  validates :user_id,    :presence => true

  validates :title,      :presence => true, :uniqueness => { :case_sensitive => false, :scope => :user_id },
                         :length => { :maximum => TITLE_LENGTH_LIMIT }

  validates :identifier, :presence => true, :uniqueness => { :case_sensitive => false, :scope => :user_id }
  validates :key,        :presence => true
  validates :key_type,   :presence => true, :inclusion => { :in => [KEY_TYPE_USER, KEY_TYPE_DEPLOY] }

  validates_associated :repository_deployment_credentials

  validate :has_not_been_changed
  validate :key_format
  validate :key_uniqueness

  ## Scopes
  scope :active,   -> { where active: STATUS_ACTIVE }
  scope :inactive, -> { where active: STATUS_LOCKED }

  scope :user_key,   -> { where key_type: KEY_TYPE_USER }
  scope :deploy_key, -> { where key_type: KEY_TYPE_DEPLOY }

  ## Callbacks
  before_validation :set_identifier
  before_validation :strip_whitespace
  before_validation :remove_control_characters

  after_commit ->(obj) { obj.add_ssh_key },     :on => :create
  after_commit ->(obj) { obj.destroy_ssh_key }, :on => :destroy


  def self.by_user(user)
    where("user_id = ?", user.id)
  end


  def to_s
    title
  end


  def set_identifier
    if !self.user_id.nil?
      self.identifier ||=
        begin
          my_time = Time.now
          time_tag = "#{my_time.to_i.to_s}_#{my_time.usec.to_s}"
          key_count = GitolitePublicKey.by_user(self.user).deploy_key.length + 1
          case key_type
            when KEY_TYPE_USER
              # add "redmine_" as a prefix to the username, and then the current date
              # this helps ensure uniqueness of each key identifier
              #
              # also, it ensures that it is very, very unlikely to conflict with any
              # existing key name if gitolite config is also being edited manually
              "#{self.user.gitolite_identifier}" << "@redmine_" << "#{time_tag}".gsub(/[^0-9a-zA-Z\-]/, '_')
            when KEY_TYPE_DEPLOY
              # add "redmine_deploy_key_" as a prefix, and then the current date
              # to help ensure uniqueness of each key identifier
              "#{self.user.gitolite_identifier}_#{DEPLOY_PSEUDO_USER}_#{key_count}".gsub(/[^0-9a-zA-Z\-]/, '_') << "@redmine_" << "#{time_tag}".gsub(/[^0-9a-zA-Z\-]/, '_')
            else
              nil
            end
          end
    else
      nil
    end
  end


  # Make sure that current identifier is consistent with current user login.
  # This method explicitly overrides the static nature of the identifier
  def reset_identifier
    # Fix identifier
    self.identifier = nil
    set_identifier

    # Need to override the "never change identifier" constraint
    self.save(:validate => false)

    self.identifier
  end


  # Key type checking functions
  def user_key?
    key_type == KEY_TYPE_USER
  end


  def deploy_key?
    key_type == KEY_TYPE_DEPLOY
  end


  def owner
    self.identifier.split('@')[0]
  end


  def location
    self.identifier.split('@')[1]
  end


  protected


  def add_ssh_key
    RedmineGitolite::GitHosting.logger.info { "User '#{User.current.login}' has added a SSH key" }
    RedmineGitolite::GitHosting.resync_gitolite({ :command => :add_ssh_key, :object => self.user.id })
  end


  def destroy_ssh_key
    RedmineGitolite::GitHosting.logger.info { "User '#{User.current.login}' has deleted a SSH key" }

    repo_key = {}
    repo_key['title']    = self.identifier
    repo_key['key']      = self.key
    repo_key['location'] = self.location
    repo_key['owner']    = self.owner

    RedmineGitolite::GitHosting.logger.info { "Delete SSH key #{self.identifier}" }
    RedmineGitolite::GitHosting.resync_gitolite({ :command => :delete_ssh_key, :object => repo_key })
  end


  private


  # Strip leading and trailing whitespace
  def strip_whitespace
    self.title = title.strip

    # Don't mess with existing keys (since cannot change key text anyway)
    if new_record?
      self.key = key.strip
    end
  end


  # Remove control characters from key
  def remove_control_characters
    # Don't mess with existing keys (since cannot change key text anyway)
    return if !new_record?

    # First -- let the first control char or space stand (to divide key type from key)
    # Really, this is catching a special case in which there is a \n between type and key.
    # Most common case turns first space back into space....
    self.key = key.sub(/[ \r\n\t]/, ' ')

    # Next, if comment divided from key by control char, let that one stand as well
    # We can only tell this if there is an "=" in the key. So, won't help 1/3 times.
    self.key = key.sub(/=[ \r\n\t]/, '= ')

    # Delete any remaining control characters....
    self.key = key.gsub(/[\a\r\n\t]/, '').strip
  end


  def has_not_been_changed
    return if new_record?

    valid = true

    %w(identifier key user_id key_type).each do |attribute|
      method = "#{attribute}_changed?"
      if self.send(method)
        errors.add(attribute, 'may not be changed')
        valid = false
      end
    end

    return valid
  end


  def key_format
    file = Tempfile.new('foo')

    begin
      file.write(key)
      file.close
      RedmineGitolite::GitHosting.execute_command(:local_cmd, "ssh-keygen -l -f #{file.path}")
      valid = true
    rescue RedmineGitolite::GitHosting::GitHostingException => e
      errors.add(:key, l(:error_key_corrupted))
      valid = false
    ensure
      file.unlink
    end

    return valid
  end


  def key_uniqueness
    return if !new_record?

    keypieces = key.match(/^(\S+)\s+(\S+)/)

    return false if keypieces.nil?

    key_format = keypieces[1]
    key_data   = keypieces[2]

    # Check against the gitolite administrator key file (owned by noone).
    all_keys = []

    all_keys.push GitolitePublicKey.new({ :user => nil, :key => File.read(RedmineGitolite::Config.get_setting(:gitolite_ssh_public_key)) })

    # Check all active keys
    all_keys += (GitolitePublicKey.active.all)

    all_keys.each do |existing_key|

      existingpieces = existing_key.key.match(/^(\S+)\s+(\S+)/)

      if existingpieces && (existingpieces[2] == key_data)
        # Hm.... have a duplicate key!
        if existing_key.user == User.current
          errors.add(:key, l(:error_key_in_use_by_you, :name => existing_key.title))
          return false
        elsif User.current.admin?
          if existing_key.user
            errors.add(:key, l(:error_key_in_use_by_other, :login => existing_key.user.login, :name => existing_key.title))
            return false
          else
            errors.add(:key, l(:error_key_in_use_by_gitolite_admin))
            return false
          end
        else
          errors.add(:key, l(:error_key_in_use_by_someone))
          return false
        end
      end
    end

    return true
  end

end
