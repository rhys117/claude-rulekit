module Detectors
  module ModelWrapperDelegation
    ROOT_MODEL = /\/app\/models\/[^\/]+\.rb\z/

    def self.call(file_path:, **)
      return false unless file_path.match?(ROOT_MODEL)
      return false if File.basename(file_path) == 'application_record.rb'

      model_name = File.basename(file_path, '.rb')
      model_dir = File.join(File.dirname(file_path), model_name)
      return false unless File.directory?(model_dir)

      siblings = Dir.glob(File.join(model_dir, '*.rb')).
        map { |f| File.basename(f, '.rb') }.
        sort
      return false if siblings.empty?

      message = <<~MSG.gsub(/\s+/, ' ').strip
        Editing root model `#{model_name}` which already has extracted sibling classes
        or concerns under app/models/#{model_name}/ (#{siblings.join(', ')}).
        Before adding logic here, ask: does this duplicate something already handled in
        a sibling? Does it represent a cohesive new responsibility worth extracting into
        its own sibling file? Does it have live callers that genuinely belong on the
        root with no overlap elsewhere? Prefer composition over inheritance to avoid god
        objects — the larger `#{model_name}` grows, the more important this discipline
        becomes. Only delegate from the root for methods with live callers; grep before
        extending the delegate list.
      MSG

      {sentinel_suffix: model_name, context: message}
    end
  end
end
