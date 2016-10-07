require 'rubygems'
require 'aws-sdk'
require 'awesome_print'
require 'zip'
require 'digest'
require 'nokogiri'
require 'open-uri'
require File.join(File.expand_path('../..', File.absolute_path(__FILE__)), '/classes/zipper.rb')

# Class that contains all of the variables and methods needed to deploy an application to Elastic Beanstalk
class AwsDeployer
  @app_name = nil
  @eb_bucket_name = nil
  @folder = nil
  @sha_hash = nil
  @zipfile_name = nil
  @credentials = nil
  @elasticbeanstalk = nil
  @s3 = nil
  @region = nil
  @endpoint_url = nil


  def initialize
    # Getting folder location and hashing the contents of the folder for versioning
    @folder = File.expand_path('../..', File.absolute_path(__FILE__))
    @sha_hash = checksum(@folder)

    # Sign into AWS
    sign_in

    # Set up the Elastic Beanstalk and S3 clients and check app name for uniqueness
    # Fail out if credentials aren't avaialble
    if @credentials and @region
      set_clients
      @app_name = check_dns_availability
    else
      raise 'Credentials or Region missing. Could not proceed.'
    end

    # Get the storage location for source bundles
    @eb_bucket_name = create_storage_location

    if @eb_bucket_name == nil
      raise 'S3 Bucket could not be created. Cannot proceed.'
    end
  end

  # Sign in to AWS. Fail out if credentials file missing or credentials invalid.
  def sign_in
    begin
      credentials_file = File.read(File.join(@folder, 'credentials.json'))
    rescue
      raise 'Credentials file not found. Exiting.'
    end

    begin
      json = JSON.parse(credentials_file)
    rescue Exception => e
      puts e
      raise 'Invalid JSON in credentials file. Exiting.'
    end

    # Check to make sure all required keys are available and if so, create Credentials object and set Region
    if json.has_key? 'access_key_id' and json.has_key? 'secret_access_key' and json.has_key? 'region'
      @credentials = Aws::Credentials.new(json['access_key_id'], json['secret_access_key'])
      @region = json['region']

      # Check to make sure region is a valid one
      unless %w{us-east-1 us-west-1 us-west-2 ap-south-1 ap-northeast-2 ap-southeast-1 ap-southeast-2 ap-northeast-1 eu-central-1 eu-west-1 sa-east-1}.include? @region
        raise 'Region not in list of regions that support Elastic Beanstalk'
      end

      return true
    else
      raise 'Missing required keys from json file. Exiting.'
    end
  end

  # Set the Elastic Beanstalk and S3 clients. Raise exception if insufficient privileges
  def set_clients
    begin
      @elasticbeanstalk = Aws::ElasticBeanstalk::Client.new(region: @region, credentials: @credentials)
      @s3 = Aws::S3::Client.new(region: @region, credentials: @credentials)
      true
    rescue Aws::ElasticBeanstalk::Errors::InsufficientPrivilegesException
      raise 'Insufficient privileges to deploy application.'
    end
  end

  # Check to see if app name is a unique CNAME prefix. If not, prompt for another until we get one to stick
  def check_dns_availability
    app_name = ''
    while app_name == ''
      app_name = prompt('Please select an app name: ')
    end

    dns_check = @elasticbeanstalk.check_dns_availability(cname_prefix: "#{app_name}")

    until dns_check and dns_check.to_h.has_key? :available and dns_check.to_h[:available] == true
      app_name = prompt('That app name has already been chosen. Please try another: ')
      dns_check = @elasticbeanstalk.check_dns_availability(cname_prefix: "#{app_name}")
    end

    app_name
  end

  # Create (or get, if already there) Elastic Beanstalk S3 storage location
  def create_storage_location
    storage_location = @elasticbeanstalk.create_storage_location
    if storage_location and storage_location.to_h.has_key? :s3_bucket
      storage_location.to_h[:s3_bucket]
    else
      nil
    end
  end

  # Zip up the source bundle and upload to S3. Check to make sure source bundle made it
  def upload_source_bundle
    exclude_filenames = ['.gitignore', '.idea', 'docker-compose.yml', 'Gemfile', 'Gemfile.lock', 'classes/zipper.rb',, 'classes/aws_deployer.rb', 'deploy.rb', '.DS_Store', '*.zip', 'credentials.json', 'credentials.json.template']
    @zipfile_name = "#{@sha_hash}.zip"
    
    zf = ZipFileGenerator.new(@folder, File.join(@folder, @zipfile_name), exclude_filenames)
    zf.write

    File.open(File.join(@folder, @zipfile_name), 'rb') do |file|
      @s3.put_object(bucket: @eb_bucket_name, key: @zipfile_name, body: file)
    end

    # Check to make sure the bundle is in S3
    begin
      @s3.get_object_acl(bucket: @eb_bucket_name, key: @zipfile_name)
      File.delete(File.join(@folder, @zipfile_name))
      return true
    rescue Aws::S3::Errors::NoSuchKey
      return false
    end
  end

  # Create a new application version with source bundle uploaded, and label using SHA hash of folder contents
  # Also creates the application if it doesn't already exist
  def create_application_version
    resp = @elasticbeanstalk.create_application_version({
      application_name: @app_name,
      auto_create_application: true,
      description: "#{@app_name} version #{@sha_hash}",
      source_bundle: {
       s3_bucket: @eb_bucket_name,
       s3_key: @zipfile_name,
      },
      version_label: @sha_hash,
    })

    # Make sure the application and application version were created
    if resp
      if resp.to_h[:application_version][:application_name] == @app_name and resp.to_h[:application_version][:version_label] == @sha_hash
        return true
      else
        return false
      end
    end
  end

  # Create Elastic Beanstalk environment using current Application Version
  # Sets up a simple single instance web server using the EB Multi-container Docker solution
  def create_environment
    resp = @elasticbeanstalk.create_environment({
       application_name: @app_name,
       environment_name: "#{@app_name}",
       solution_stack_name: '64bit Amazon Linux 2016.03 v2.1.7 running Multi-container Docker 1.11.2 (Generic)',
       version_label: @sha_hash,
       cname_prefix: "#{@app_name}",
       option_settings: [
         {
           namespace: 'aws:elasticbeanstalk:sns:topics',
           option_name: 'Notification Endpoint',
           value: 'jrohrer1@gmail.com'
         },
         {
           namespace: 'aws:elasticbeanstalk:environment',
           option_name: 'ServiceRole',
           value: 'aws-elasticbeanstalk-service-role'
         },
         {
           namespace: 'aws:elasticbeanstalk:environment',
           option_name: 'EnvironmentType',
           value: 'SingleInstance'
         },
         {
           namespace: 'aws:elasticbeanstalk:healthreporting:system',
           option_name: 'SystemType',
           value: 'enhanced'
         },
         {
           namespace: 'aws:elasticbeanstalk:healthreporting:system',
           option_name: 'HealthCheckSuccessThreshold',
           value: 'Ok'
         },
         {
           namespace: 'aws:ec2:vpc',
           option_name: 'Subnets',
           value: 'subnet-3897925c'
         },
         {
           namespace: 'aws:ec2:vpc',
           option_name: 'VPCId',
           value: 'vpc-32687456'
         },
         {
           namespace: 'aws:ec2:vpc',
           option_name: 'AssociatePublicIpAddress',
           value: 'true'
         },
         {
           namespace: 'aws:autoscaling:launchconfiguration',
           option_name: 'SecurityGroups',
           value: 'sg-52ef5e2b'
         },
         {
           namespace: 'aws:autoscaling:launchconfiguration',
           option_name: 'IamInstanceProfile',
           value: 'aws-elasticbeanstalk-ec2-role'
         },
         {
           namespace: 'aws:autoscaling:launchconfiguration',
           option_name: 'InstanceType',
           value: 't2.nano'
         },
         {
           namespace: 'aws:autoscaling:launchconfiguration',
           option_name: 'EC2KeyName',
           value: 'mini-project'
         }
       ]
     })

    # Make sure the environment is actually launching
    if resp and resp.to_h[:status] == 'Launching'
      @endpoint_url = resp.to_h[:cname]
      true
    else
      false
    end
  end

  # Checks the current health of the environment in real time. Posts updates as they come in until
  # environment health is OK and status is Ready
  # If error, return false and bomb out.
  def check_health
    healthcheck = false
    error = nil
    status = nil
    health = nil
    request_time = Time.now

    until healthcheck or error do
      env_resp = @elasticbeanstalk.describe_environments(
        environment_names: ["#{@app_name}"],
        include_deleted: false
      )
      event_resp = @elasticbeanstalk.describe_events(
        environment_name: "#{@app_name}",
        start_time: request_time,
        end_time: Time.now
      )
      if env_resp
        env = env_resp.to_h[:environments].first
        if env
          if env[:health_status] == 'Ok' and env[:status] == 'Ready'
            puts 'Healthy!'
            healthcheck = true
          else
            current_status = env[:status]
            current_health = env[:health_status]
            if current_status != status
              puts "Status: #{current_status}"
              status = current_status
            end
            if current_health != health
              puts "Health: #{current_health}"
              health = current_health
            end
            if event_resp
              event_resp.to_h[:events].each do |event|
                puts event[:message]
              end
            end
            request_time = Time.now
            sleep 5
          end
        end
      else
        error = 'Could not check health of environment. Are you sure it exists?'
      end

      if healthcheck == true and error == nil
        true
      else
        false
      end
    end

    true
  end

  # Uses Nokogiri to parse the DOM of the newly created web site to verify the correct content
  def verify_page_contents
    page = nil

    begin
      page = Nokogiri::HTML(open("http://#{@endpoint_url}"))
    rescue
      puts 'Could not open page.'
      return false
    end

    begin
      page_text = page.css('body h1')[0].text
      if page_text == 'Automation for the People'
        return true
      else
        return false
      end
    rescue
      puts 'Required element not found.'
      return false
    end
  end

  def get_endpoint_url
    @endpoint_url
  end

  # Returns a SHA hash of the contents of a directory
  def checksum(dir)
    files = Dir["#{dir}/**/*"].reject{|f| File.directory?(f)}
    content = files.map{|f| File.read(f)}.join
    md5 = Digest::MD5.new
    md5 << content
    md5.hexdigest
  end

  # I have to ask you questions somehow, right?
  def prompt(*args)
    print(*args)
    gets.chomp
  end
end
