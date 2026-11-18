# Native functions are implemented by compiler/native/{prism,platform}.nelua.
module KahNative
  ffi_func :kah_native_same_file, [:str, :str], :int
  ffi_func :kah_native_temp, [:str], :str
  ffi_func :kah_native_run, [:str, :str, :str, :size_t, :size_t], :int
  ffi_func :kah_native_init, [], :void
  ffi_func :kah_native_parse, [:str, :size_t], :ptr
  ffi_func :kah_native_close, [:ptr], :void
  ffi_func :kah_native_root, [:ptr], :long
  ffi_func :kah_native_kind, [:ptr, :long], :str
  ffi_func :kah_native_ref, [:ptr, :long, :str], :long
  ffi_func :kah_native_count, [:ptr, :long, :str], :long
  ffi_func :kah_native_child, [:ptr, :long, :str, :long], :long
  ffi_func :kah_native_integer, [:ptr, :long, :str], :long
  ffi_func :kah_native_float, [:ptr, :long], :double
  ffi_func :kah_native_flag, [:ptr, :long, :str], :long
  ffi_func :kah_native_string, [:ptr, :long, :str], :binstr
  ffi_func :kah_native_text, [:ptr, :long, :str], :long
  ffi_func :kah_native_text_byte, [:ptr, :long], :int
  ffi_func :kah_native_errors, [:ptr], :long
  ffi_func :kah_native_error_line, [:ptr, :long], :long
  ffi_func :kah_native_error_message, [:ptr, :long], :str
end

class KahAST
  attr_reader :path
  def initialize(source, path)
    @path = path
    @pointer = KahNative.kah_native_parse(source, source.bytesize)
    raise "cannot allocate Prism context" if @pointer == nil
  end
  def close
    KahNative.kah_native_close(@pointer)
  end
  def root
    KahNative.kah_native_root(@pointer)
  end
  def kind(id)
    name = KahNative.kah_native_kind(@pointer, id)
    if name == "ItParametersNode"
      "NumberedParametersNode"
    elsif name == "ItLocalVariableReadNode"
      "LocalVariableReadNode"
    else
      name
    end
  end
  def raw_kind(id)
    KahNative.kah_native_kind(@pointer, id)
  end
  def ref(id, name)
    child = KahNative.kah_native_ref(@pointer, id, name)
    if child >= 0 && raw_kind(child) == "ImplicitNode"
      child = KahNative.kah_native_ref(@pointer, child, "value")
    end
    child
  end
  def list(id, name)
    count = KahNative.kah_native_count(@pointer, id, name)
    result = []
    i = 0
    while i < count
      result << KahNative.kah_native_child(@pointer, id, name, i)
      i += 1
    end
    result
  end
  def int(id, name)
    if name == "maximum" && raw_kind(id) == "ItParametersNode"
      1
    else
      KahNative.kah_native_integer(@pointer, id, name)
    end
  end
  def float(id)
    KahNative.kah_native_float(@pointer, id)
  end
  def flag(id, name)
    KahNative.kah_native_flag(@pointer, id, name) != 0
  end
  def text(id, name)
    if name == "name" && raw_kind(id) == "ItLocalVariableReadNode"
      return "_1"
    end
    if name == "filepath" && raw_kind(id) == "SourceFileNode"
      return @path
    end
    KahNative.kah_native_string(@pointer, id, name)
  end
  def error_count
    KahNative.kah_native_errors(@pointer)
  end
  def error_line(index)
    KahNative.kah_native_error_line(@pointer, index)
  end
  def error_message(index)
    KahNative.kah_native_error_message(@pointer, index)
  end
end
