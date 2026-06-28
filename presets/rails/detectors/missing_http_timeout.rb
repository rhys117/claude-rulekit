module Detectors
  # Fires when code uses an HTTP client without configuring a timeout. Unions the
  # on-disk file with the incoming edit so a timeout set elsewhere in the same
  # file silences the nudge. A timeout configured in a separate initializer or a
  # wrapper class can't be seen from here — if that's your setup, ignore it.
  module MissingHttpTimeout
    CLIENT = /\bNet::HTTP\b|\bFaraday\b|\bHTTParty\b|\bRestClient\b|\bTyphoeus\b|\bExcon\b/
    TIMEOUT = /\b(open_timeout|read_timeout|write_timeout|timeout)\b|Timeout\.timeout/

    def self.call(file_path:, new_content:, **)
      existing = File.exist?(file_path) ? File.read(file_path) : ''
      content = "#{existing}\n#{new_content}"

      return false unless CLIENT.match?(content)
      return false if TIMEOUT.match?(content)

      true
    end
  end
end
