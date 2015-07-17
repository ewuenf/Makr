

# This extension provides classes enabling the compilation of source files, construction of binaries, dynamic and static
# libraries with the standard GNU tool chain part of many important linux distributions
module Makr




  # Represents a standard compiled source unit that has dependencies to included files (and any deps that a user may specify).
  # The input files are dependencies on FileTasks including the source itself. Another dependency exists on the
  # target object file, so that the task rebuilds, if that file was deleted or modified otherwise. Also the
  # task has a dependency on the Config object that contains the compiler options etc. so that a change in these
  # also triggers recompilation (see also ConfigTask). The variable CompileTask.excludeSystemHeaders controls, wether
  # dependency checking is extended to system header files or not (the former is more costly, default is not to do
  # this).
  class CompileTask < Task


    # builds up the string used for calling the compiler out of the given Config (or default values),
    # the dependencies are not included (this is done in update)
    def makeCompilerCallString() # g++ is the general default value
      if @config then
        Makr.log.debug("CompileTask " + @name + ": config name is: \"" + @config.name + "\"")
        callString = (@config["compiler"].empty?)?"g++ ":(@config["compiler"] + " ") # g++ as default value
        # now add other flags and options
        callString += " " + @config["compiler.cFlags"]       + " " if @config["compiler.cFlags"]
        callString += " " + @config["compiler.defines"]      + " " if @config["compiler.defines"]
        callString += " " + @config["compiler.includePaths"] + " " if @config["compiler.includePaths"]
        callString += " " + @config["compiler.otherOptions"] + " " if @config["compiler.otherOptions"]
        return callString
      else
        Makr.log.debug("CompileTask " + @name + ": no config given, using bare g++")
        return "g++ "
      end
    end

    alias :getConfigString :makeCompilerCallString


    # this variable influences dependency checking by the compiler ("-M" or "-MM" option)
    @@excludeSystemHeaders = true
    def CompileTask.excludeSystemHeaders
      @@excludeSystemHeaders
    end
    def CompileTask.excludeSystemHeaders=(arg)
      @@excludeSystemHeaders = arg
    end


    # make a unique name for CompileTasks out of the fileName which is to be compiled
    def CompileTask.makeName(fileName)
      "CompileTask__" + fileName
    end


    # we strive to make a unique name even if source files with identical names exist by
    # taking the whole path and replacing directory seperators with underscores
    def makeObjectFileName(fileName)
      # substitution of '_' with '__' prevents collisions
      @build.buildPath + "/" + fileName.gsub('_', '__').gsub('/', '_').gsub('.', '_') + ".o"
    end


    # the path of the input and output file of the compilation
    attr_reader :fileName, :objectFileName
    attr_accessor :excludeSystemHeaders


    # arguments: fileName contains the file to be compiled, build references the Build object containing the tasks
    # (including this one), config is the optional Config, fileIsGenerated specifies that
    # the file to be compiled is generated (for example by the moc from Qt). If fileIsGenerated is true, the
    # last argument must contain the task that generates it to add a dependency.
    # The options accepted in the Config referenced by config could be "compiler", "compiler.cFlags", "compiler.defines"
    # "compiler.includePaths", "compiler.otherOptions" (see also function makeCompilerCallString() )
    def initialize(fileName, build, config = nil, fileIsGenerated = false, generatorTask = nil)
      @fileName = Makr.cleanPathName(fileName)
      # now we need a unique name for this task. As we're defining a FileTask as dependency to fileName
      # and a FileTask on the @objectFileName to ensure a build of the target if it was deleted or
      # otherwise modified (whatever you can think of here), we need a unique name not related to these
      super(CompileTask.makeName(@fileName), config)
      @build = build

      # the dep tasks, that are constructed below are not added yet to the dependencies Array as this is done
      # in buildDependencies(), called before update

      # first construct a dependency on the file itself, if it isnt generated
      # (we dont add dependencies yet, as they get added upon automatic dependency generation in
      # the function buildDependencies())
      @fileIsGenerated = fileIsGenerated
      @generatorTaskDep = generatorTask
      if not @fileIsGenerated then
        @compileFileDep = @build.getOrMakeNewTask(@fileName) {FileTask.new(@fileName)}
      end

      # construct a dependency task on the target object file
      @objectFileName = makeObjectFileName(fileName)
      @compileTargetDep = @build.getOrMakeNewTask(@objectFileName) {FileTask.new(@objectFileName, false)}
      @targets = [@objectFileName] # set targets produced by this task
      deleteTargets() # delete targets upon construction to guarantee a first update

      # construct a dependency task on the configuration
      @configTaskDep = @build.getOrMakeNewTask(ConfigTask.makeName(@name)) {ConfigTask.new(ConfigTask.makeName(@name))}

      # then add the dependencies constructed above
      File.delete(@objectFileName + ".d") rescue nil # first delete an existing dep file

      # we call this here to safe code, although no dep file exists, still we need to add the
      # static dependencies (@compileFileDep,...)
      buildDependencies()

      Makr.log.debug("made CompileTask with @name=\"" + @name + "\"") # debug feedback
    end


    # parses the dependencies eventually generated by the compiler.
    # Parsing is seperated from dependency generation because during the update step we also check
    # dependencies but do no rebuild them as the tree should not be changed during multi-threaded update
    def buildDependencies()
      clearDependencies()

      # first we add the constructed dependencies as we simply cleared *all* deps before
      addDependency(@compileFileDep) if not @fileIsGenerated
      addDependency(@compileTargetDep)
      addDependency(@configTaskDep)
      addDependency(@generatorTaskDep) if @fileIsGenerated

      return if not @dependencyLines # only go on if we have compiler generated deps

      dependencyFiles = Array.new
      @dependencyLines.each do |depLine|
        depLine.strip! # remove white space and newlines
        # remove backslash on each line, if present (GCC output is guaranteed to produce only a single backslash at line end)
        if depLine.include?('\\') then
          depLine.chop!
        end
        if depLine.include?(':') # the "xyz.o"-target specified by the compiler in the "Makefile"-rule needs to be skipped
          splitArr = depLine.split(": ")
          dependencyFiles.concat(splitArr[1].split(" ")) if splitArr[1]
        else
          dependencyFiles.concat(depLine.split(" "))
        end
      end
      dependencyFiles.each do |depFile|
        depFile.strip!
        next if depFile.empty?
        depFile = Makr.cleanPathName(depFile)
        next if (depFile == @fileName) # go on if dependency on source file encountered
        if @build.hasTask?(depFile) then
          task = @build.getTask(depFile)
          if not @dependencies.include?(task)
            addDependency(task)
          end
        elsif (task = @build.getTaskForTarget(depFile)) then
          if not @dependencies.include?(task)
            addDependency(task)
          end
        else
          task = FileTask.new(depFile)
          @build.addTask(depFile, task)
          addDependency(task)
        end
        task.update()
      end

    end


    def makeCompileCommand()
      # we combine compilation with dep-file generation as this reduces the number of compiler calls and is safer
      # this is inspired by the managed build of eclipse CDT
      # also the dep files could be used by anyone else
      # build dir gets a little more cluttered
      # benchmarks indicate this solution to be superior to reading the deps from a pipe with an extra compiler call
      excludeSystemHeaders = (@excludeSystemHeaders)? @excludeSystemHeaders : @@excludeSystemHeaders
      return makeCompilerCallString() + " -c \"" + @fileName + "\" -o \"" + @objectFileName + "\"" +
               ((excludeSystemHeaders)?" -MMD ":" -MD ") + " -MF\"" + @objectFileName + ".d\""
      # for explanation of switches refer to "man gcc"
    end


    def update()
      @state = nil # first set state to unsuccessful build

      # always clear input lines upon call
      @dependencyLines = nil

      # then check, if we need to to perform anything or just have an error
      if (@fileIsGenerated and (not File.file?(@fileName))) then
        Makr.log.error("generated file is missing: #{@fileName}")
        return false
      end
      
      # construct compiler command and execute it
      compileCommand = makeCompileCommand()
      
      # output is colorized using ANSI escape codes (see also http://stackoverflow.com/questions/1489183/colorized-ruby-output)
      Makr.log.info("Compiling \033[32m#{@fileName}\033[0m")
      Makr.log.debug("CompileTask \033[32m#{@name}\033[0m is executing compiler:\n\t" + compileCommand)

      # we use a pipe here to protect the user from interleaved output, just gathering
      # compiler output ourselves and then print out synchronously. Therefore, we
      # redirect cerr with [+ " 2>&1"], as gcc will output errors there and the pipe only reads cout
      compilerPipe = IO.popen(compileCommand + " 2>&1")
      compilerOutput = compilerPipe.read
      compilerPipe.close
      successful = ($?.exitstatus == 0) # exit status is different from zero upon compile error

      # output is colorized using ANSI escape codes (see also http://stackoverflow.com/questions/1489183/colorized-ruby-output)
      if not successful then  # check if we had a compiler error
        Makr.log.error( "\n\n\033[31m\n#\n#\n# Errors compiling #{@fileName}:\n#\n#\n\033[0m\n\n" + 
                        "##### using command:\n\n#{compileCommand}\n\n#####\n\n\n" + 
                        "#{compilerOutput}\n\n\n\n"
                      )
      elsif not compilerOutput.empty? then # no compiler error, but compiler output (typically warnings)
        Makr.log.warn ( "\n\n\033[33m\n#\n#\n# Warnings compiling #{@fileName}:\n#\n#\n\033[0m\n\n" + 
                        "##### using command:\n\n#{compileCommand}\n\n#####\n\n\n" + 
                        "#{compilerOutput}\n\n\n\n"
                      )
      else
        # we only do debug output in this case, for not to clutter the build output
        Makr.log.debug("Successfully completed CompileTask #{@name}")
      end

      @compileTargetDep.update() # update file information on the compiled target in any case

      # compiler generated deps, we read them back in here already for performance reasons, 
      # as we assume them to be in OS cache still, parsing still is done in postUpdate, to not modify
      # the tree before update finishes
      if File.exist?(@objectFileName + ".d") then
        @dependencyLines = File.open(@objectFileName + ".d").readlines
      end
      # indicate successful update by setting state string to preliminary concat string (set correctly in postUpdate)
      @state = concatStateOfDependencies() if successful
    end


    def postUpdate()      
      buildDependencies() # needs to be called even if update was not successful !!
      super
    end

  end









  # Generator classes used in conjunction with Makr.applyGenerators(fileCollection, generatorArray). See examples.
  # The generate(fileName)-functions in each class return an Array of tasks, that contains all generated tasks or
  # is empty in case of failure.
  # Produces a CompileTask for every fileName given, if it does not exist. All CompileTask objects get the config given.
  class CompileTaskGenerator

    def initialize(build, config = nil)
      @build = build
      @config = config
    end


    def generate(fileName)
      fileName = Makr.cleanPathName(fileName)
      compileTaskName = CompileTask.makeName(fileName)
      if not @build.hasTask?(compileTaskName) then
        @build.addTask(compileTaskName, CompileTask.new(fileName, @build, @config))
      end
      localTask = @build.getTask(compileTaskName)
      localTask.config = @config
      dummyTaskArray = [localTask]
      @build.pushTaskToFileHash(fileName, dummyTaskArray)
      return dummyTaskArray
    end
  end













  # Linking tasks follow.
  #
  #
  # A general note from 'man ld';
  #
  # Note---if the linker is being invoked indirectly, via a compiler driver (e.g. gcc) then all the linker command line
  # options should be prefixed by -Wl, (or whatever is appropriate for the particular compiler driver) like this:
  #
  #                  gcc -Wl,--start-group foo.o bar.o -Wl,--end-group
  #
  # This is important, because otherwise the compiler driver program may silently drop the linker options, resulting
  # in a bad link.


  # This class constructs a dynamic library.
  # Creating a dynamic lib requires compiling the object files with -fPIC or -fpic flag handed to the compiler
  # (this is checked upon update() !).
  class DynamicLibTask < Task

    # special dynamic lib thingies (see http://www.faqs.org/docs/Linux-HOWTO/Program-Library-HOWTO.html)


    attr_reader    :libName  # basename of the lib to be build
    attr_reader    :libFileName  # full path of the lib to be build (but not necessarily absolute path, depends on user)


    # make a unique name
    def DynamicLibTask.makeName(libName)
       "DynamicLibTask__" + libName
    end


    # checks each dependency if it includes the compiler flag "-fPIC" or "-fpic", if it is a CompileTask
    def checkDependencyTasksForPIC()
      @dependencies.each do |dep|
        if dep.kind_of?(CompileTask) then
          raise "[makr] DynamicLibTask wants configName in dependency CompileTask #{dep.name}!" if not dep.config
          if (not (dep.config["compiler.cFlags"].include?("-fPIC") or dep.config["compiler.cFlags"].include?("-fpic"))) then
            raise( "[makr] DynamicLibTask wants -fPIC or -fpic in config[\"compiler.cFlags\"] of dependency CompileTasks!" +
                    " error occured in CompileTask " + dep.name)
          end
        end
      end
    end


    # we subdivide linker and options here as we want the options at the end of the command
    # to avoid problems with static libs specified as options

    def makeLinkerString()
      if @config then
        return (@config["linker"].empty?)?"g++ ":(@config["linker"] + " ") # g++ is default value
      else
        return "g++ "
      end
    end


    def makeOptionsString()
      if @config then
        # flags and options
        optionsString  = " " + @config["linker.lFlags"]       + " " if @config["linker.lFlags"]
        optionsString += " " + @config["linker.libPaths"]     + " " if @config["linker.libPaths"]
        optionsString += " " + @config["linker.libs"]         + " " if @config["linker.libs"]
        optionsString += " " + @config["linker.otherOptions"] + " " if @config["linker.otherOptions"]
        # add mandatory "-shared" etc if necessary
        optionsString += " -shared " if not optionsString.include?("-shared")
        optionsString += (" -Wl,-soname," + @libName) if not optionsString.include?("-soname")
        return optionsString
      else
        return " -shared -Wl,-soname," + @libName
      end
    end


    def getConfigString()
      if @config then
        Makr.log.debug("DynamicLibTask " + @name + ": config name is: \"" + @config.name + "\"")
        return makeLinkerString() + makeOptionsString()
      else
        Makr.log.debug("no config given, using bare linker g++")
        return "g++ -shared -Wl,-soname," + @libName
      end
    end


    # libFileName should be the complete path (absolute or relative) of the library with all standard fuss, like
    # "build/libxy.so.1.2.3"
    # (if you want a different soname for the lib, pass it as option with the config,
    # for example like this: config["linker.otherOptions"]=" -Wl,-soname,libSpecialName.so.1")
    # The options accepted in the config could be "linker", "linker.lFlags",
    # "linker.libs" and "linker.otherOptions" (see also function makeLinkerCallString() ).
    def initialize(libFileName, build, config = nil)
      @libFileName = Makr.cleanPathName(libFileName)
      @libName = File.basename(@libFileName)
      super(DynamicLibTask.makeName(@libFileName), config)
      @build = build

      # we need a dep on the lib target
      @libTargetDep = @build.getOrMakeNewTask(@libFileName) {FileTask.new(@libFileName, false)}
      addDependency(@libTargetDep)
      @targets = [@libFileName]

      # now add another dependency task on the config
      @configDep = @build.getOrMakeNewTask(ConfigTask.makeName(@name)) {ConfigTask.new(ConfigTask.makeName(@name))}
      addDependency(@configDep)

      Makr.log.debug("made DynamicLibTask with @name=\"" + @name + "\"")
    end


    def update()
      @state = nil # first set state to unsuccessful build

      # we always check for properly setup dependencies
      checkDependencyTasksForPIC()
      # build compiler command and execute it
      linkCommand = makeLinkerString()
      @dependencies.each do |dep|
        # we only want CompileTask dependencies from which we use the objectFileName
        linkCommand += " " + dep.objectFileName if dep.kind_of?(CompileTask)
      end
      linkCommand += makeOptionsString() + " -o " + @libFileName

      # output is colorized using ANSI escape codes (see also http://stackoverflow.com/questions/1489183/colorized-ruby-output)
      Makr.log.info("Building dynamic lib \033[32m#{@libFileName}\033[0m")
      Makr.log.debug("Building DynamicLibTask \033[32m#{@name}\033[0m\n\t" + linkCommand)
      
      successful = system(linkCommand)
      
      Makr.log.error("\033[31mErrors\033[0m building dynamic lib #{@libFileName}") if not successful
      @libTargetDep.update() # update file information on the compiled target in any case

      # indicate successful update by setting state string to preliminary concat string (set correctly in postUpdate)
      @state = concatStateOfDependencies() if successful
    end

  end





  # constructs a dynamic lib target with the given taskCollection as dependencies, takes an optional libConfig
  # for configuration options. Sets default task in build!
  def Makr.makeDynamicLib(libFileName, build, taskCollection, libConfig = nil)
    libFileName = Makr.cleanPathName(libFileName)
    libTaskName = DynamicLibTask.makeName(libFileName)
    if not build.hasTask?(libTaskName) then
      build.addTask(libTaskName, DynamicLibTask.new(libFileName, build, libConfig))
    end
    libTask = build.getTask(libTaskName)
    libTask.config = libConfig
    libTask.clearAll()
    libTask.addDependencies(taskCollection)
    build.defaultTask = libTask # set this as default task in build
    return libTask
  end




















  # This class constructs a static library. No special flags are needed as compared to DynamicLibTask regarding
  # the CompileTasks (see http://www.faqs.org/docs/Linux-HOWTO/Program-Library-HOWTO.html).
  # The standard construction is: "ar rcs my_library.a file1.o file2.o ..."
  class StaticLibTask < Task

    attr_reader    :libName  # basename of the lib to be build
    attr_reader    :libFileName  # path of the lib to be build (does not need to be absolute)


    # make a unique name
    def StaticLibTask.makeName(libName)
       "StaticLibTask__" + libName
    end


    def makeLinkerCallString() # "ar rcs " is default value
      if @config then
        Makr.log.debug("StaticLibTask " + @name + ": config name is: \"" + @config.name + "\"")
        return (@config["linker"].empty?)?"ar rcs ":(@config["linker"] + " ")
      else
        Makr.log.debug("no @config given, using bare linker ar")
        return "ar rcs "
      end
    end

    alias :getConfigString :makeLinkerCallString


    # libFileName should be the complete path (absolute or relative) of the library with all standard fuss, like "build/libxy.a".
    # Specifying a config is typically unnecessary, the only entry respected is config["linker"].
    def initialize(libFileName, build, config)
      @libFileName = Makr.cleanPathName(libFileName)
      @libName = File.basename(@libFileName)
      super(StaticLibTask.makeName(@libFileName), config)
      @build = build

      # first we need a dependency on the target
      @libTargetDep = @build.getOrMakeNewTask(@libFileName) {FileTask.new(@libFileName, false)}
      addDependency(@libTargetDep)
      @targets = [@libFileName]

      # now add another dependency task on the config
      @configDep = @build.getOrMakeNewTask(ConfigTask.makeName(@name)) {ConfigTask.new(ConfigTask.makeName(@name))}
      addDependency(@configDep)

      Makr.log.debug("made StaticLibTask with @name=\"" + @name + "\"")
    end


    def update()
      @state = nil # first set state to unsuccessful build

      # build compiler command and execute it
      linkCommand = makeLinkerCallString() + @libFileName
      @dependencies.each do |dep|
        # we only want CompileTask dependencies from which we use the objectFileName
        linkCommand += " " + dep.objectFileName if dep.kind_of?(CompileTask)
      end
      
      # output is colorized using ANSI escape codes (see also http://stackoverflow.com/questions/1489183/colorized-ruby-output)
      Makr.log.info("Building static lib \033[32m#{@libFileName}\033[0m")
      Makr.log.debug("Building StaticLibTask \033[32m#{@name}\033[0m\n\t" + linkCommand)
      
      successful = system(linkCommand)
      
      Makr.log.error("\033[31mErrors\033[0m building static lib #{@libFileName}") if not successful

      @libTargetDep.update() # update file information on the compiled target in any case

      # indicate successful update by setting state string to preliminary concat string (set correctly in postUpdate)
      @state = concatStateOfDependencies() if successful
    end

  end




  # constructs a static lib target with the given taskCollection as dependencies, takes an optional libConfig
  # for configuration options. Sets default task in build!
  def Makr.makeStaticLib(libFileName, build, taskCollection, libConfig = nil)
    libFileName = Makr.cleanPathName(libFileName)
    libTaskName = StaticLibTask.makeName(libFileName)
    if not build.hasTask?(libTaskName) then
      build.addTask(libTaskName, StaticLibTask.new(libFileName, build, libConfig))
    end
    libTask = build.getTask(libTaskName)
    libTask.config = libConfig
    libTask.clearAll()
    libTask.addDependencies(taskCollection)
    build.defaultTask = libTask # set this as default task in build
    return libTask
  end


















  # This class represents a task that builds a program binary made up from all dependencies that
  # define an objectFileName-member. If static libraries are linked in via StaticLibTask, a group
  # statement will be used (see "man ld") to alleviate cyclic dependencies. As this imposes a little
  # performance overhead the user may of course choose to not enable this. See member useStaticLibsGroup
  class ProgramTask < Task

    # identifies the binary to be build, wants full path as usual
    attr_reader    :programName
    # Array of String, specifying the path + file name to additional static libs,
    # these are linked last in the order of this Array, any strange static lib
    # dependencies (like necessary multiple inclusion) may be solved using this
    # variable.
    attr_accessor  :extraStaticLibs, :useStaticLibsGroup, :useGoldLinker


    # make a unique name for ProgramTasks out of the programName which is to be compiled
    # expects a Pathname or a String
    def ProgramTask.makeName(programName)
       "ProgramTask__" + programName
    end


    # we subdivide linker and options here as we want the options at the end of the command
    # to avoid problems with static libs specified as options

    def makeLinkerString()
      if @config then
        return (@config["linker"].empty?)?"g++ ":(@config["linker"] + " ") # g++ is default value
      else
        return "g++ "
      end
    end


    def makeOptionsString()
      if @config then
        # flags and options
        optionsString  = " " + @config["linker.lFlags"]       + " " if @config["linker.lFlags"]
        optionsString += " " + @config["linker.libPaths"]     + " " if @config["linker.libPaths"]
        optionsString += " " + @config["linker.libs"]         + " " if @config["linker.libs"]
        optionsString += " " + @config["linker.otherOptions"] + " " if @config["linker.otherOptions"]
        return optionsString
      else
        return String.new # no options, empty string
      end

    end


    def getConfigString()
      if @config then
        Makr.log.debug("ProgramTask " + @name + ": config name is: \"" + @config.name + "\"")
        configString =  makeLinkerString() + makeOptionsString()
      else
        Makr.log.debug("no config given, using bare linker g++")
        configString =  "g++ "
      end
      configString + @extraStaticLibs.join(' ')
    end


    # The options accepted in the config could be "linker", "linker.lFlags",
    # "linker.libs" and "linker.otherOptions" (see also function makeLinkerCallString() ).
    def initialize(programName, build, config)
      @programName = Makr.cleanPathName(programName)
      super(ProgramTask.makeName(@programName), config)
      @build = build

      # first we make dependency on the target program file
      @targetDep = @build.getOrMakeNewTask(@programName) {FileTask.new(@programName, false)}
      addDependency(@targetDep)
      @targets = [@programName]

      # now add another dependency task on the config
      @configDep = @build.getOrMakeNewTask(ConfigTask.makeName(@name)) {ConfigTask.new(ConfigTask.makeName(@name))}
      addDependency(@configDep)

      @extraStaticLibs = Array.new # for static libs specified by user
      @useStaticLibsGroup = true
      @useGoldLinker = false

      Makr.log.debug("made ProgramTask with @name=\"" + @name + "\"")
    end


    # Add the file name of a static lib to be linked in, that cannot be automatically deduced (which is normally done
    # by checking all direct dependencies if they are a StaticLibTask). The member extraStaticLibs, that is modified
    # here can also be accessed directly (its an array of file names)
    def addStaticLibFile(fileName)
      Makr.cleanPathName(fileName)
      @extraStaticLibs.push(fileName) if not @extraStaticLibs.include?(fileName)
    end


    def makeInputFilesString()
      retString = String.new
      # first we want them object files
      @dependencies.each do |dep|
        retString += " " + dep.objectFileName if dep.kind_of?(CompileTask)
      end
      # then the dynamic libs
      @dependencies.each do |dep|
        retString += " " + dep.libFileName if dep.kind_of?(DynamicLibTask)
      end
      # and at the end the static libs to avoid linker issues (maybe add them twice, also at the front?)
      retString += " -Wl,--start-group" if @useStaticLibsGroup
      @dependencies.each do |dep|
        retString += " " + dep.libFileName if dep.kind_of?(StaticLibTask)
      end
      retString += " -Wl,--end-group" if @useStaticLibsGroup
      return (retString += " " + @extraStaticLibs.join(' '))
    end


    def update()
      @state = nil # first set state to unsuccessful build

      # build compiler command and execute it

      # first construct gold linker string if wanted (this is just about adding
      # a linker path to g++ using the -B option)
      useGoldLinkerString = String.new
      useGoldLinkerString = " -B#{$makrExtensionsDir}" if useGoldLinker

      linkCommand = makeLinkerString() + useGoldLinkerString + " -o " + @programName +
                    makeInputFilesString() + makeOptionsString()

      # output is colorized using ANSI escape codes (see also http://stackoverflow.com/questions/1489183/colorized-ruby-output)
      Makr.log.info("Building program \033[32m#{@programName}\033[0m")
      Makr.log.debug("Building ProgramTask \033[32m#{@name}\033[0m\n\t" + linkCommand)
      
      successful = system(linkCommand)
      
      Makr.log.error("\033[31mErrors\033[0m building program #{@programName}") if not successful

      @targetDep.update() # update file information on the compiled target in any case

      # indicate successful update by setting state string to preliminary concat string (set correctly in postUpdate)
      @state = concatStateOfDependencies() if successful
    end

  end



  # constructs a ProgramTask with the given taskCollection as dependencies, takes an optional programConfig
  # for configuration options. Sets default task in build!
  def Makr.makeProgram(progName, build, taskCollection, programConfig = nil)
    progName = Makr.cleanPathName(progName)
    programTaskName = ProgramTask.makeName(progName)
    if not build.hasTask?(programTaskName) then
      build.addTask(programTaskName, ProgramTask.new(progName, build, programConfig))
    end
    progTask = build.getTask(programTaskName)
    progTask.config = programConfig
    progTask.clearAll()
    progTask.addDependencies(taskCollection)
    build.defaultTask = progTask # set this as default task in build
    return progTask
  end








end     # end of module makr ######################################################################################




