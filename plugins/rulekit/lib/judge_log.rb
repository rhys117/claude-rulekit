require 'fileutils'
require 'json'
require 'time'

# One JSON line per Stop pass and per judge request, in the session's dir, so
# what the judge was asked, and why a pass asked nothing, can be read back.
module JudgeLog
  module_function

  def append(session_dir, entry)
    FileUtils.mkdir_p(session_dir)
    line = JSON.generate({ at: Time.now.utc.iso8601(3) }.merge(entry))
    File.open(File.join(session_dir, 'judge.log'), 'a') { |file| file.puts(line) }
  end
end
