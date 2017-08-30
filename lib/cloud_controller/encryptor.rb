require 'securerandom'
require 'openssl/cipher'
require 'base64'

module VCAP::CloudController::Encryptor
  class << self
    ALGORITHM = 'AES-128-CBC'.freeze

    def generate_salt
      SecureRandom.hex(4).to_s
    end

    def encrypt(input, salt, label=nil)
      return nil unless input
      Base64.strict_encode64(run_cipher(make_cipher.encrypt, input, salt, label))
    end

    def decrypt(encrypted_input, salt, label=nil)
      return nil unless encrypted_input
      run_cipher(make_cipher.decrypt, Base64.decode64(encrypted_input), salt, label)
    end

    #
    # Get encrypted field

    attr_accessor :db_encryption_key


    def database_encryption_keys=(keys)
      @@db_keys = keys
    end

    private

    def database_encryption_keys
      @@db_keys ||= Hash.new
    end

    def make_cipher
      OpenSSL::Cipher::Cipher.new(ALGORITHM)
    end

    def key(label)
      return(database_encryption_keys[label])
    end

    def run_cipher(cipher, input, salt, label=nil)
      key_to_use = key(label)

      unless key_to_use != nil
        key_to_use = db_encryption_key
      end

      cipher.pkcs5_keyivgen(key_to_use, salt)
      cipher.update(input).tap { |result| result << cipher.final }
    end
  end

  module FieldEncryptor
    extend ActiveSupport::Concern

    module ClassMethods
      def encrypt(field_name, options={})
        field_name = field_name.to_sym
        salt_name = (options[:salt] || "#{field_name}_salt").to_sym
        generate_salt_name = "generate_#{salt_name}".to_sym
        storage_column = options[:column]

        unless columns.include?(salt_name)
          raise "Salt field `#{salt_name}` does not exist"
        end

        define_method generate_salt_name do
          return unless send(salt_name).blank?
          send "#{salt_name}=", VCAP::CloudController::Encryptor.generate_salt
        end

        if storage_column
          define_method field_name do
            send storage_column
          end

          define_method "#{field_name}=" do |value|
            send "#{storage_column}=", value
          end
        end

        define_method "#{field_name}_with_encryption" do
          VCAP::CloudController::Encryptor.decrypt send("#{field_name}_without_encryption"), send(salt_name)
        end
        alias_method_chain field_name, 'encryption'

        define_method "#{field_name}_with_encryption=" do |value|
          send generate_salt_name

          encrypted_value =
            if value.blank?
              nil
            else
              kl = send(:key_label)
              VCAP::CloudController::Encryptor.encrypt(value, send(salt_name), !kl.nil? ? kl : nil)
            end

          send "#{field_name}_without_encryption=", encrypted_value
        end
        alias_method_chain "#{field_name}=", 'encryption'
      end
      private :encrypt
    end
  end
end
