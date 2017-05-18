require 'json'
require 'tempfile'
require 'fileutils'

module DPL
  class Provider
    class Lambda < Provider
      requires 'aws-sdk'
      requires 'rubyzip', load: 'zip'

      def lambda
        @lambda ||= ::Aws::Lambda::Client.new(lambda_options)
      end

      def lambda_options
        {
          region:      options[:region] || 'us-east-1',
          credentials: ::Aws::Credentials.new(option(:access_key_id), option(:secret_access_key))
        }
      end

      def push_app

        # The original LambdaPreview client supported create/update in one call
        # To keep compatibility we try to fetch the function and then decide
        # whether to update the code or create a new function

        function_name = options[:name] || option(:function_name)

        if all_lambda_functions.any? { |function| function.function_name == function_name }

          log "Function #{function_name} already exists, updating."

          # Options defined at
          #   https://docs.aws.amazon.com/sdkforruby/api/Aws/Lambda/Client.html#update_function_configuration-instance_method
          response = lambda.update_function_configuration({
              function_name:  function_name,
              description:    options[:description]    || default_description,
              timeout:        options[:timeout]        || default_timeout,
              memory_size:    options[:memory_size]    || default_memory_size,
              role:           option(:role),
              handler:        handler,
              runtime:        options[:runtime]        || default_runtime,
          })


          log "Updated configuration of function: #{response.function_name}."

          # Options defined at
          #   https://docs.aws.amazon.com/sdkforruby/api/Aws/Lambda/Client.html#update_function_code-instance_method
          response = lambda.update_function_code({
            function_name:  options[:name] || option(:function_name),
            zip_file:       function_zip,
            publish:        publish,
          })

          log "Updated code of function: #{response.function_name}."
        else
          # Options defined at
          #   https://docs.aws.amazon.com/lambda/latest/dg/API_CreateFunction.html
          response = lambda.create_function({
            function_name:  options[:name]           || option(:function_name),
            description:    options[:description]    || default_description,
            timeout:        options[:timeout]        || default_timeout,
            memory_size:    options[:memory_size]    || default_memory_size,
            role:           option(:role),
            handler:        handler,
            code: {
              zip_file:     function_zip,
            },
            runtime:        options[:runtime]        || default_runtime,
            publish:        publish,
          })

          log "Created lambda: #{response.function_name}."
        end
      rescue ::Aws::Lambda::Errors::ServiceException => exception
        error(exception.message)
      rescue ::Aws::Lambda::Errors::InvalidParameterValueException => exception
        error(exception.message)
      rescue ::Aws::Lambda::Errors::ResourceNotFoundException => exception
        error(exception.message)
      end

      def handler
        module_name = options[:module_name] || default_module_name
        handler_name = option(:handler_name)

        "#{module_name}.#{handler_name}"
      end

      def function_zip
        target_zip_path = File.absolute_path(options[:zip] || Dir.pwd)
        dest_file_path = output_file_path

        if File.directory?(target_zip_path)
          zip_directory(dest_file_path, target_zip_path)
        elsif File.file?(target_zip_path)
          zip_file(dest_file_path, target_zip_path)
        else
          error('Invalid zip option. If set, must be path to directory, js file, or a zip file.')
        end

        File.new(dest_file_path)
      end

      def zip_file(dest_file_path, target_file_path)
        if File.extname(target_file_path) == '.zip'
          # Just copy it to the destination right away, since it is already a zip.
          FileUtils.cp(target_file_path, dest_file_path)
          dest_file_path
        else
          # Zip up the file.
          src_directory_path = File.dirname(target_file_path)
          files = [ target_file_path ]

          create_zip(dest_file_path, src_directory_path, files)
        end
      end

      def zip_directory(dest_file_path, target_directory_path)
        files = Dir[File.join(target_directory_path, '**', '**')]
        create_zip(dest_file_path, target_directory_path, files)
      end

      def create_zip(dest_file_path, src_directory_path, files)
        Zip::File.open(dest_file_path, Zip::File::CREATE) do |zipfile|
          files.each do |file|
            zipfile.add(file.sub(src_directory_path + File::SEPARATOR, ''), file)
          end
        end

        dest_file_path
      end

      def needs_key?
        false
      end

      def check_auth
        log "Using Access Key: #{option(:access_key_id)[-4..-1].rjust(20, '*')}"
      end

      def output_file_path
        @output_file_path ||= '/tmp/' + random_chars(8) + '-lambda.zip'
      end

      def default_runtime
        'nodejs'
      end

      def default_timeout
        3 # seconds
      end

      def default_description
        "Deploy build #{context.env['TRAVIS_BUILD_NUMBER']} to AWS Lambda via Travis CI"
      end

      def default_memory_size
        128
      end

      def default_module_name
        'index'
      end

      def publish
        !!options[:publish]
      end

      def random_chars(count=8)
        (36**(count-1) + rand(36**count - 36**(count-1))).to_s(36)
      end

      def cleanup
      end

      def uncleanup
      end

      def all_lambda_functions
        response = lambda.list_functions
        functions = response.functions
        marker = response.next_marker
        until marker.empty? do
          response = lambda.list_functions(marker: marker)
          functions += response.functions
          marker = response.next_marker
        end

        functions
      end
    end
  end
end
