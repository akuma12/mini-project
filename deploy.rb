#!/usr/bin/env ruby

require File.join(File.dirname(File.absolute_path(__FILE__)), '/classes/aws_deployer.rb')

deployer = AwsDeployer.new

puts 'Uploading Source Bundle to S3...'
if deployer.upload_source_bundle
  puts 'Source bundle Uploaded. Creating Application and Application Version...'
  if deployer.create_application_version
    puts 'Application and Application Version Created. Creating Environment...'
    if deployer.create_environment
      puts 'Environment Launching, please wait...'
      if deployer.check_health
        puts 'Environment healthy and ready. Checking page content...'
        if deployer.verify_page_contents
          puts '"Automation for the People" found!'
          puts "Go to #{deployer.get_endpoint_url} to see for yourself!"
        else
          puts 'Page contents don\'t match "Automation for the People"'
        end
      else
        puts 'Could not check Environment Health.'
      end
    else
      puts 'Could not create Environment.'
    end
  else
    puts 'Could not create Application or Application Version.'
  end
else
  puts 'Could not upload Source Bundle.'
end