#!/usr/bin/env ruby

input_file_path = ARGV[0]
included_headers = [ "Arduino.h" ]
import_regexp = /^\s*#include\s*[<"](\S+)[">]/

def first_statement(source)
  header_regex = /\s+|(\/\*([^\*]|[\r\n]|(\*+([^\*\/]|[\r\n])))*\*+\/)|(\/\/.*)|(\#(?:[^\n\r])*)/m

  index = 0
  source.enum_for(:scan, header_regex).each do
    last_match = Regexp.last_match
    start_at = last_match.begin(0)
    break if index != start_at
    index = start_at + last_match[0].size
  end

  index = index - 1
  index = 0 if index < 0
  index
end

source = File.read(input_file_path)
included_headers += source.scan(import_regexp).flatten

prototype_regex = /[\w\[\]\*]+\s+[&\[\]\*\w\s]+\([&,\[\]\*\w\s]*\)(?=\s*;)/
function_regex = /[\w\[\]\*]+\s+[&\[\]\*\w\s]+\([&,\[\]\*\w\s]*\)(?=\s*\{)/

prototypes = source.scan(function_regex) - source.scan(prototype_regex)

injection_index = first_statement(source)
source.insert injection_index, <<END
#include <Arduino.h>
#{prototypes.map{ |x| x+=";" }.join("\n")}

END

puts source
