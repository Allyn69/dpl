module Dpl
  module Providers
    class Elasticbeanstalk < Provider
      status :alpha

      full_name 'AWS Elastic Beanstalk'

      description sq(<<-str)
        tbd
      str

      gem 'aws-sdk-elasticbeanstalk', '~> 1.0'
      gem 'aws-sdk-s3', '~> 1.0'
      gem 'rubyzip', '~> 1.2.2', require: 'zip'
      gem 'pathspec', '~> 0.2.1', require: 'pathspec'

      env :aws, :elastic_beanstalk
      config '~/.aws/credentials', '~/.aws/config', prefix: 'aws'

      opt '--access_key_id ID', 'AWS Access Key ID', required: true, secret: true
      opt '--secret_access_key KEY', 'AWS Secret Key', required: true, secret: true
      opt '--region REGION', 'AWS Region the Elastic Beanstalk app is running in', default: 'us-east-1'
      opt '--app NAME', 'Elastic Beanstalk application name', default: :repo_name
      opt '--env NAME', 'Elastic Beanstalk environment name which will be updated', required: true
      opt '--bucket NAME', 'Bucket name to upload app to', required: true, alias: :bucket_name
      opt '--bucket_path PATH', 'Location within Bucket to upload app to'
      opt '--description DESC', 'Description for the application version'
      opt '--label LABEL', 'Label for the application version'
      opt '--zip_file PATH', 'The zip file that you want to deploy'
      opt '--only_create_app_version', 'Only create the app version, do not actually deploy it'
      opt '--wait_until_deployed', 'Wait until the deployment has finished'
      opt '--debug', internal: true

      msgs login:   'Using Access Key: %{access_key_id}',
           zip_add: 'Adding %s'

      msgs clean_description: 'Removed non-printable characters from the version description'

      attr_reader :started, :object, :version

      def login
        info :login
      end

      def setup
        info :login
        Aws.config.update(credentials: credentials, region: region)
      end

      def deploy
        @started = Time.now
        bucket.create unless bucket.exists?
        create_zip unless zip_exists?
        upload
        create_version
        update_app unless only_create_app_version?
      end

      def zip_file
        zip_file? ? expand(super) : archive_name
      end

      def archive_name
        "#{label}.zip"
      end

      def label
        @label ||= super || "travis-#{git_sha}-#{Time.now.to_i}"
      end

      def description
        super || git_commit_msg
      end

      def bucket_path
        bucket_path? ? "#{super.gsub(/\/*$/, '')}/#{archive_name}" : archive_name
      end

      def cwd
        @cwd ||= "#{Dir.pwd}/"
      end

      def zip_exists?
        File.exists?(zip_file)
      end

      def create_zip
        ::Zip::File.open(zip_file, ::Zip::File::CREATE) do |zip|
          files.each do |path|
            debug :zip_add, path
            zip.add(path.sub(cwd, ''), path)
          end
        end
      end

      def upload
        @object = bucket.object(bucket_path)
        object.put(body: File.open(zip_file))
        sleep 5 # s3 eventual consistency
      end

      def create_version
        @version = eb.create_application_version(
          application_name: app,
          version_label: label,
          description: clean(description[0, 200]),
          source_bundle: {
            s3_bucket: bucket.name,
            s3_key: object.key
          },
          auto_create_application: false
        )
      end

      def update_app
        eb.update_environment(
          environment_name: env,
          version_label: version[:application_version][:version_label]
        )
        wait_until_deployed if wait_until_deployed?
      end

      def wait_until_deployed
        msgs = []
        1.upto(20) { return if check_deployment(msgs) }
        error 'Too many failures'
      end

      def check_deployment(msgs)
        sleep 5
        events.each do |event|
          msg = "#{event.event_date} [#{event.severity}] #{event.message}"
          error "Deployment failed: #{msg}" if event.severity == 'ERROR'
          info msg unless msgs.include?(msg)
          msgs << msg
        end
        environment[:status] == 'Ready'
      rescue Aws::Errors::ServiceError => e
        info "Caught #{e}: #{e.message}. Retrying ..."
      end

      def files
        files = Dir.glob('**/*', File::FNM_DOTMATCH)
        ignore = %w(.ebignore .gitignore).detect { |file| file?(file) }
        files = filter(files, ignore) if ignore
        files
      end

      def filter(files, spec)
        spec = PathSpec.from_filename(spec)
        files.reject { |file| spec.match(file) }
      end

      def events
        args = { environment_name: env, start_time: started.utc.iso8601 }
        eb.describe_events(args)[:events].reverse
      end

      def environment
        args = { application_name: app, environment_names: [env] }
        eb.describe_environments(args)[:environments].first
      end

      def credentials
        Aws::Credentials.new(access_key_id, secret_access_key)
      end

      def s3
        @s3 ||= Aws::S3::Resource.new
      end

      def bucket
        @bucket ||= s3.bucket(super)
      end

      def eb
        @eb ||= Aws::ElasticBeanstalk::Client.new(retry_limit: 10)
      end

      # We do not actually know what characters are valid on AWS EB's side,
      # see: https://github.com/aws/aws-sdk-ruby/issues/1502
      #
      # Reference: https://www.w3.org/TR/xml/#charsets
      NON_PRINTABLE_CHARS = "\u0009\u000A\u000D\u0020-\uD7FF\uE000-\uFFFD\u10000-\u10FFFF"

      def clean(str)
        str.gsub!(/[^#{NON_PRINTABLE_CHARS}]/, '') && info(:clean_description)
        str
      end

      def debug(*args)
        info *args if debug?
      end
    end
  end
end
