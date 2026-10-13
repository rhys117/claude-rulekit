# What one hook run gave back.
HookResult = Struct.new(:stdout, :stderr, :exit_code) do
  def to_s
    stdout
  end
end
