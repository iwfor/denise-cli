# frozen_string_literal: true

require "openssl"
require "securerandom"
require "base64"
require "fileutils"

module Denise
  # Encrypts/decrypts provider API tokens at rest using a key file that
  # denise creates (0600) on first use, under Paths.key_file.
  class Crypto
    CIPHER_NAME = "aes-256-gcm"
    KEY_BYTES = 32
    IV_BYTES = 12
    AUTH_TAG_BYTES = 16

    def initialize(key_path: Paths.key_file)
      @key_path = key_path
      ensure_key!
    end

    def encrypt(plaintext)
      cipher = OpenSSL::Cipher.new(CIPHER_NAME)
      cipher.encrypt
      cipher.key = key
      iv = cipher.random_iv
      ciphertext = cipher.update(plaintext) + cipher.final
      Base64.strict_encode64(iv + cipher.auth_tag + ciphertext)
    end

    def decrypt(encoded)
      raw = Base64.strict_decode64(encoded)
      iv = raw[0, IV_BYTES]
      auth_tag = raw[IV_BYTES, AUTH_TAG_BYTES]
      ciphertext = raw[(IV_BYTES + AUTH_TAG_BYTES)..]

      cipher = OpenSSL::Cipher.new(CIPHER_NAME)
      cipher.decrypt
      cipher.key = key
      cipher.iv = iv
      cipher.auth_tag = auth_tag
      cipher.update(ciphertext) + cipher.final
    end

    private

    def key
      @key ||= File.binread(@key_path)
    end

    # Key is created once and never rotated automatically: rotating it
    # would silently orphan every already-encrypted token in the config.
    def ensure_key!
      FileUtils.mkdir_p(File.dirname(@key_path))
      create_key! unless File.exist?(@key_path)
      File.chmod(0o600, @key_path)
    end

    # Created 0600 atomically (O_EXCL), never written with default
    # permissions and chmod'ed afterward - that would leave a window where
    # another local user could read the key. If another process wins the
    # race to create it, keep theirs rather than clobbering it.
    def create_key!
      File.open(@key_path, File::WRONLY | File::CREAT | File::EXCL | File::BINARY, 0o600) do |f|
        f.write(SecureRandom.random_bytes(KEY_BYTES))
      end
    rescue Errno::EEXIST
      nil
    end
  end
end
