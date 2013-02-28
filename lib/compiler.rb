require 'digest/sha1'
require 'fileutils'

module ArduinoKit
  class Compiler
    # DIR
    ARDUINO_HOME     = "/Applications/Arduino.app/Contents/Resources/Java"
    ARDUINO_CORE     = "#{ARDUINO_HOME}/hardware/arduino/cores/arduino"
    ARDUINO_VARIANTS = "#{ARDUINO_HOME}/hardware/arduino/variants"
    ARDUINO_LIBS     = "#{ARDUINO_HOME}/libraries"
    ARDUINO_EXT_LIBS = "#{ENV["HOME"]}/Documents/Arduino/libraries"
    AVR_HOME         = "#{ARDUINO_HOME}/hardware/tools/avr"
    AVR_BIN          = "#{AVR_HOME}/bin"

    # CMD
    AVR_GPP     = "#{AVR_BIN}/avr-g++"
    AVR_GCC     = "#{AVR_BIN}/avr-gcc"
    AVR_AR      = "#{AVR_BIN}/avr-ar"
    AVR_OBJCOPY = "#{AVR_BIN}/avr-objcopy"
    AVRDUDE     = "#{AVR_BIN}/avrdude"

    # METADATA
    ARDUINO_VERSION = File.read("#{ARDUINO_HOME}/lib/version.txt").gsub(".", "")

    # REGEXES
    IMPORT_REGEX    = /^\s*#include\s*[<"](\S+)[">]/
    PROTOTYPE_REGEX = /[\w\[\]\*]+\s+[&\[\]\*\w\s]+\([&,\[\]\*\w\s]*\)(?=\s*;)/
    FUNCTION_REGEX  = /[\w\[\]\*]+\s+[&\[\]\*\w\s]+\([&,\[\]\*\w\s]*\)(?=\s*\{)/
    FIRST_REGEX     = /\s+|(\/\*([^\*]|[\r\n]|(\*+([^\*\/]|[\r\n])))*\*+\/)|(\/\/.*)|(\#(?:[^\n\r])*)/m

    def initialize(source_path, build_path)
      @verbose = true
      @board = {
        mcu: "atmega32u4",
        cpu: "16000000L",
        vid: "0x2341",
        pid: "0x8036",
        variant: "leonardo"
      }
      @source = {
        path: source_path,
        name: File.basename(source_path),
        sha1: Digest::SHA1.hexdigest(source_path)
      }
      @build_path = "#{build_path}/#{@source[:sha1]}"
      @target_source = "#{@build_path}/#{@source[:name]}_HEADER_APPENDED.cpp"

      @headers = []
      @include_paths = [ ARDUINO_CORE ]
      @include_paths << "#{ARDUINO_VARIANTS}/#{@board[:variant]}" if @board[:variant]

      FileUtils.mkdir_p(@build_path)
    end

    def compile
      pre_processing

      @object_files = []

      compile_step_1_target_source
      compile_step_2_included_headers
      compile_step_3_arduino_core
      compile_step_4_link_all_into_elf
      compile_step_5_extract_eeprom_to_eep
      compile_step_6_build_hex

      return "#{@target_source}.hex"
    end

    private

    def first_statement(source)
      index = 0
      source.enum_for(:scan, FIRST_REGEX).each do
        last_match = Regexp.last_match
        start_at = last_match.begin(0)
        break if index != start_at
        index = start_at + last_match[0].size
      end

      index = index - 1
      index = 0 if index < 0
      index
    end

    def pre_processing
      source = File.read(@source[:path])

      @headers += source.scan(IMPORT_REGEX).flatten

      prototypes = source.scan(FUNCTION_REGEX) - source.scan(PROTOTYPE_REGEX)
      injection_index = first_statement(source)
      source.insert injection_index, <<END
#include <Arduino.h>
#{prototypes.map{ |x| x+=";" }.join("\n")}

END

      File.write(@target_source, source)
    end

    def library_path(header)
      name = header.sub(/\.h$/, "")

      official_lib = "#{ARDUINO_LIBS}/#{name}"
      custom_lib   = "#{ARDUINO_EXT_LIBS}/#{name}"

      return official_lib if File.exist?(official_lib)
      return custom_lib   if File.exist?(custom_lib)
    end

    def source_files(path)
      sources = {}
      Dir["#{path}/*"].each do |f|
        case f
        when /\.s$/
          (sources[:s] ||= []) << f
        when /\.c$/
          (sources[:c] ||= []) << f
        when /\.cpp$/
          (sources[:cpp] ||= []) << f
        end
      end
      sources
    end

    # -I needs
    #   1. core
    #   2. variant
    #   3. includes
    def compile_step_1_target_source
      include_paths = @include_paths.clone

      @headers.each do |h|
        if path = library_path(h)
          include_paths << path
        end
      end

      @object_files += compile_files(@build_path,
                                     include_paths,
                                     source_files(@build_path))
    end

    # -I needs
    #   1. core
    #   2. variant
    #   3. includes
    #   4. includes's utility # whatever it exist or not
    def compile_step_2_included_headers
      include_paths = @include_paths.clone

      @headers.each do |h|
        normal_path  = library_path(h)
        utility_path = "#{library_path(h)}/utility"

        lib_build_path = "#{@build_path}/#{h.sub(/\.h$/, "")}"
        lib_utility_build_path = "#{lib_build_path}/utility"

        FileUtils.mkdir_p(lib_build_path)
        FileUtils.mkdir_p(lib_utility_build_path)

        #normal
        normal_include_paths = include_paths + [ normal_path ]
        @object_files += compile_files(lib_build_path,
                                       normal_include_paths,
                                       source_files(normal_path))

        #utility
        utility_include_paths = include_paths + [ normal_path, utility_path  ]
        @object_files += compile_files(lib_utility_build_path,
                                       utility_include_paths,
                                       source_files(utility_path))
      end
    end

    # -I needs
    #   1. core
    #   2. variant
    def compile_step_3_arduino_core
      include_paths = @include_paths.clone

      core_object_files = compile_files(@build_path,
                                   include_paths,
                                   source_files(ARDUINO_CORE))

      # collecting them into the core.a library file.
      base_cmd = [
        AVR_AR,
        "rcs",
        "#{@build_path}/core.a"
      ].join(" ")

      core_object_files.each do |of|
        puts [
          base_cmd,
          of
        ].join(" ")
      end
    end

    def compile_step_4_link_all_into_elf
      cmd = [
        AVR_GCC,
        "-Os",
        "-Wl,--gc-sections" + (@board[:mcu] == "atmega2560" ? ",--relax" : ""),
        "-mmcu=" + @board[:mcu],
        "-o",
        "#{@target_source}.elf"
      ]

      @object_files.each { |of| cmd << of }

      cmd += [
        "#{@build_path}/core.a",
        "-L" + @build_path,
        "-lm"
      ]

      puts cmd.join(" ")
    end

    def compile_step_5_extract_eeprom_to_eep
      cmd = [
        AVR_OBJCOPY,
        "-O",
        "ihex",
        "-j",
        ".eeprom",
        "--set-section-flags=.eeprom=alloc,load",
        "--no-change-warnings",
        "--change-section-lma",
        ".eeprom=0",
        "#{@target_source}.elf",
        "#{@target_source}.eep"
      ]

      puts cmd.join(" ")
    end

    def compile_step_6_build_hex
      cmd = [
        AVR_OBJCOPY,
        "-O",
        "ihex",
        "-R",
        ".eeprom",
        "#{@target_source}.elf",
        "#{@target_source}.hex"
      ]

      puts cmd.join(" ")
    end

    def compile_files(build_path, include_paths, sources={})
      object_files = []

      (sources[:s] || []).each do |s|
        object_path = "#{build_path}/#{File.basename(s)}.o"
        object_files << object_path

        compile_s(include_paths, s, object_path)
      end

      (sources[:c] || []).each do |s|
        object_path = "#{build_path}/#{File.basename(s)}.o"
        depend_path = "#{build_path}/#{File.basename(s)}.d"
        object_files << object_path

        compile_c(include_paths, s, object_path)
      end

      (sources[:cpp] || []).each do |s|
        object_path = "#{build_path}/#{File.basename(s)}.o"
        depend_path = "#{build_path}/#{File.basename(s)}.d"
        object_files << object_path

        compile_cpp(include_paths, s, object_path)
      end

      object_files
    end

    def compile_s(include_paths, source_name, object_name)
      cmd = [
        AVR_GCC,
        "-c", # compile, don't link
        "-g", # include debugging info (so errors include line numbers)
        "-assembler-with-cpp",
        "-mmcu=" + @board[:mcu],
        "-DARDUINO=" + ARDUINO_VERSION,
        "-DF_CPU=" + @board[:cpu],
        "-DUSB_VID=" + @board[:vid],
        "-DUSB_PID=" + @board[:pid]
      ]

      include_paths.each do |p|
        cmd << "-I#{p}"
      end

      cmd << source_name
      cmd << "-o #{object_name}"

      cmd = cmd.join(" ")
      puts cmd
    end

    def compile_c(include_paths, source_name, object_name)
      cmd = [
        AVR_GCC,
        "-c", # compile, don't link
        "-g", # include debugging info (so errors include line numbers)
        "-Os", # optimize for size
        @verbose ? "-Wall" : "-w", # show warnings if verbose
        "-ffunction-sections", # place each function in its own section
        "-fdata-sections",
        "-mmcu=" + @board[:mcu],
        "-MMD", # output dependancy info
        "-DARDUINO=" + ARDUINO_VERSION,
        "-DF_CPU=" + @board[:cpu],
        "-DUSB_VID=" + @board[:vid],
        "-DUSB_PID=" + @board[:pid]
      ]

      include_paths.each do |p|
        cmd << "-I#{p}"
      end

      cmd << source_name
      cmd << "-o #{object_name}"

      cmd = cmd.join(" ")
      puts cmd
    end

    def compile_cpp(include_paths, source_name, object_name)
      cmd = [
        AVR_GPP,
        "-c", # compile, don't link
        "-g", # include debugging info (so errors include line numbers)
        "-Os", # optimize for size
        @verbose ? "-Wall" : "-w", # show warnings if verbose
        "-fno-exceptions",
        "-ffunction-sections", # place each function in its own section
        "-fdata-sections",
        "-mmcu=" + @board[:mcu],
        "-MMD", # output dependancy info
        "-DARDUINO=" + ARDUINO_VERSION,
        "-DF_CPU=" + @board[:cpu],
        "-DUSB_VID=" + @board[:vid],
        "-DUSB_PID=" + @board[:pid]
      ]

      include_paths.each do |p|
        cmd << "-I#{p}"
      end

      cmd << source_name
      cmd << "-o #{object_name}"

      cmd = cmd.join(" ")
      puts cmd
    end
  end
end

hex = ArduinoKit::Compiler.new(`realpath #{ARGV[0]}`.strip, "/tmp/arduinokit/build").compile

serial_port = "/dev/tty.usbmodemfa131"

# REBOOT
puts "echo \"Forcing reset using 1200bps open/close on port #{serial_port}\""
puts "stty -F #{serial_port} 1200 cs8 cread clocal; sleep 1"

# UPLOAD
puts "echo \"Uploading...\""
puts "#{ArduinoKit::Compiler::AVRDUDE} -C#{ArduinoKit::Compiler::AVR_HOME}/etc/avrdude.conf -v -patmega32u4 -cavr109 -P#{serial_port} -b57600 -D -Uflash:w:#{hex}:i"
