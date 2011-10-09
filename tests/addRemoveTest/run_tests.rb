#!/usr/bin/ruby

require 'ftools'

$sourceLinesHeader =
  [
  "#ifndef HEADER_NAME",
  "#define HEADER_NAME",
  "",
  "class NAME",
  "{",
  "public:",
  " static void f();",
  "};",
  "",
  "#endif"
  ]



$sourceLinesSource =
  [
  "#include <NAME.h>",
  "#include <iostream>",
  "",
  "void NAME::f()",
  "{",
  "  std::cout << \"Here in NAME::f()\" << std::endl;",
  "};",
  ""
  ]


def replaceAndWrite(lines, repString, io)
  lines.each do |line|
    io << line.gsub("NAME", repString) << "\n";
  end
end


def writeSourceAndHeader(repString)
  File.open("baseFiles/" + repString + ".h", "w+")   {|file| replaceAndWrite($sourceLinesHeader, repString, file)}
  File.open("baseFiles/" + repString + ".cpp", "w+") {|file| replaceAndWrite($sourceLinesSource, repString, file)}
end


def writeMain(nameArray)
  File.open("src/main.cpp", "w+") do |file|
    nameArray.each do |name|
      file << "#include <" << name << ".h>\n"
    end
    file << "\n\nint main(int argc, char * argv[])\n{\n"
    nameArray.each do |name|
      file << "  " << name << "::f();\n"
    end
    file << "\nreturn 0;\n}\n\n"
  end
end


$nameArray = ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N"]

system("rm -rf baseFiles")
Dir.mkdir("baseFiles")

$nameArray.each do |s|
  writeSourceAndHeader(s)
end


currentFileNamesArray = Array.new
system("rm -rf src")
Dir.mkdir("src")
system("rm -rf build")
Dir.mkdir("build")

overallSuccess = true


51.times do |i|

  puts "################################### >>>>>>>>>>>>>>> Run Nr. " + i.to_s

  delNameArray = $nameArray.select { rand(0) < 0.17 }
  delNameArray.each {|name| system("rm -f src/" + name + ".h src/" + name + ".cpp")}

  addNameArray = $nameArray.select { rand(0) < 0.1 }
  addNameArray.each do |name|
    system("cp -f baseFiles/" + name + ".h src/" + name + ".h") if not File.file?("src/" + name + ".h")
    system("cp -f baseFiles/" + name + ".cpp src/" + name + ".cpp")  if not File.file?("src/" + name + ".cpp")
  end

  # now modify currentFileNamesArray to reflect both deld and added file names
  currentFileNamesArray = currentFileNamesArray.select {|name| not delNameArray.include?(name)}
  addNameArray.each {|name| currentFileNamesArray.push(name) if not currentFileNamesArray.include?(name)}
  writeMain(currentFileNamesArray)

  successful = system("../../makr.rb build")

  # check build files
  foundAllFiles = true
  currentFileNamesArray.each do |name|
    foundAllFiles = foundAllFiles and File.file?("build/__src_" + name + "_cpp.o")
  end
  foundAllFiles = foundAllFiles and File.file?("build/__src_main_cpp.o")
  foundAllFiles = foundAllFiles and File.file?("build/myProgram")

  # check program output
  programPipe = IO.popen("build/myProgram")
  progOutputLines = programPipe.readlines
  foundAllOuputExpected = currentFileNamesArray.empty?
  currentFileNamesArray.each do |name|
    findArray = progOutputLines.select { |line| line.include?(name + "::f()") }
    if not (foundAllOuputExpected = (findArray.size == 1)) then
      break
    end
  end

  puts "Makr run was successful = " + successful.to_s + " and foundAllFiles = " + foundAllFiles.to_s +
       " and foundAllOuputExpected = " + foundAllOuputExpected.to_s

  puts currentFileNamesArray if not foundAllOuputExpected

  break if not ( overallSuccess = (successful and foundAllFiles and foundAllOuputExpected) )
  
end

# keep dirs if we were not successful to that we can investigate
system("rm -rf src") if overallSuccess
system("rm -rf build") if overallSuccess
system("rm -rf baseFiles") if overallSuccess

