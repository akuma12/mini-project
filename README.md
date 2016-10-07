# Automated Deployment with Elastic Beanstalk and Docker

This project is an example of an automated deployment of a Docker web server to AWS Elastic Beanstalk.

### Dependencies

1. Ruby 2.0 or later - download here: https://www.ruby-lang.org/en/downloads/
2. Rubygems - download here: https://rubygems.org/pages/download
3. Bundler - Once Ruby and Rubygems are installed, run ```gem install bundler```

### Setup

1. Run ```bundle install``` in the project directory to install the required Gems.
2. Execute ```cp credentials.json.template credentials.json``` or manually copy credentials.json.template to credentials.json.
3. Enter your AWS Access Key ID, AWS Secret Access Key, and desired AWS Region in the credentials.json.

### Deploy Application

From the command line, run ```deploy.rb``` and follow the prompts.

That's it!