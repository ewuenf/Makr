

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
        callString = String.new
        if (not @config["compiler"]) then
          Makr.log.warn("CompileTask " + @name + ": no compiler given, using default g++")
          callString = "g++ "
        else
          callString = @config["compiler"] + " "
        end
        # now add additionyl flags and options
        callString += @config["compiler.cFlags"]       + " " if @config["compiler.cFlags"]
        callString += @config["compiler.defines"]      + " " if @config["compiler.defines"]
        callString += @config["compiler.includePaths"] + " " if @config["compiler.includePaths"]
        callString += @config["compiler.otherOptions"] + " " if @config["compiler.otherOptions"]
        return callString
      else
        Makr.log.warn("CompileTask " + @name + ": no config given, using bare g++")
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
      buildDependencies()

      Makr.log.debug("made CompileTask with @name=\"" + @name + "\"") # debug feedback
    end


    # method is used in getDepsStringArrayFromCompiler() below
    def makeDependencyCheckingCommand()
      # do we also want system header deps?
      # the local variable overrides class variable if set
      excludeSystemHeaders = (@excludeSystemHeaders)? @excludeSystemHeaders : @@excludeSystemHeaders
      # system headers are excluded using compiler option "-MM", else "-M"
      # -MG is for ignoring missing header files, that may be generated
      # we hardcode this options right now, as this build tool is limited to compilers adhering to gcc's interface
      # (if we have a compiler that does not, then we may also need to exchange the dependency parsing)
      depCommand = makeCompilerCallString() + @fileName + ((excludeSystemHeaders)?" -MM ":" -M ") + " -MG "
    end


    # calls compiler with complete configuration options to automatically generate a list of dependency files
    # the list is parsed in buildDependencies()
    # Parsing is seperated from dependency generation because during the update step we also check
    # dependencies but do no rebuild them as the tree should not be changed during multi-threaded update
    # function return true, if successful, false otherwise
    def getDepsStringArrayFromCompiler()
      # always clear input lines upon call
      @dependencyLines = nil

      # then check, if we need to to
      if (@fileIsGenerated and (not File.file?(@fileName))) then
        Makr.log.error("generated file is missing: #{@fileName}")
        return false
      end

      # construct dependency checking command and execute it
      depCommand = makeDependencyCheckingCommand()
      Makr.log.info("Executing compiler to check for dependencies in CompileTask: \"" + @name + "\"\n\t" + depCommand)
      compilerPipe = IO.popen(depCommand)  # in ruby >= 1.9.2 we could use Open3.capture2(...) for this purpose
      @dependencyLines = compilerPipe.readlines
      compilerPipe.close
      if $?.exitstatus != 0 then # $? is thread-local, so this should be safe in multi-threaded update
        Makr.log.fatal( "error #{$?.exitstatus} in CompileTask for file \"" + @fileName +
                        "\" making dependencies failed, check file for syntax errors!")
        return false # error case
      end
      return true # success case
    end


    # parses the dependency files generated by the compiler in getDepsStringArrayFromCompiler().
    # Parsing is seperated from dependency generation because during the update step we also check
    # dependencies but do no rebuild them as the tree should not be changed during multi-threaded update
    def buildDependencies()
      clearDependencies()

      # first we add the constructed dependencies as we simply cleared *all* deps before
      addDependency(@compileFileDep) if not @fileIsGenerated
      addDependency(@compileTargetDep)
      addDependency(@configTaskDep)
      addDependency(@generatorTaskDep) if @fileIsGenerated

      # compiler generated deps
      return if not @dependencyLines # only go on if we havem
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


    def makeCompileCommand() # construction now uses gcc flag notation
      return makeCompilerCallString() + " -c " + @fileName + " -o " + @objectFileName
    end


    def update()
      @state = nil # first set state to unsuccessful build

      # here we execute the compiler to deliver an update on the dependent includes before compilation. We could do this
      # in postUpdate, too, but we assume this to be faster, as the files should be in OS cache afterwards and
      # thus the compilation (which is the next step) should be faster
      return if not getDepsStringArrayFromCompiler()

      # construct compiler command and execute it
      compileCommand = makeCompileCommand()
      Makr.log.info("CompileTask #{@name}: Executing compiler\n\t" + compileCommand)
      successful = system(compileCommand)
      Makr.log.error("Error in CompileTask #{@name}") if not successful
      @compileTargetDep.update() # update file information on the compiled target in any case

      # indicate successful update by setting state string to preliminary concat string (set correctly in postUpdate)
      @state = concatStateOfDependencies() if successful
    end


    def postUpdate()
      buildDependencies()  # assuming we have called the compiler already in update giving us the deps strings
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
      # care for changed configName when config is from cache
      if localTask.config != @config then
        Makr.log.debug( "config has changed in task " + localTask.name + \
                       " compared to cached version, setting to new value: " + @config.name)
        localTask.config = @config
      end
      dummyTaskArray = [localTask]
      @build.pushTaskToFileHash(fileName, dummyTaskArray)
      return dummyTaskArray
    end
  end



  






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


    def makeLinkerCallString() # g++ is always default value
      if @config then
        Makr.log.debug("DynamicLibTask " + @name + ": config name is: \"" + @config.name + "\"")
        callString = String.new
        if (not @config["linker"]) then
          Makr.log.warn("no linker command given, using default g++")
          callString = "g++ "
        else
          callString = @config["linker"] + " "
        end
        # now add other flags and options
        callString += @config["linker.lFlags"]       + " " if @config["linker.lFlags"]
        callString += @config["linker.libPaths"]     + " " if @config["linker.libPaths"]
        callString += @config["linker.libs"]         + " " if @config["linker.libs"]
        callString += @config["linker.otherOptions"] + " " if @config["linker.otherOptions"]
        # add mandatory "-shared" etc if necessary
        callString += " -shared " if not callString.include?("-shared")
        callString += (" -Wl,-soname," + @libName) if not callString.include?("-soname")
        return callString
      else
        Makr.log.warn("no config given, using bare linker g++")
        return "g++ -shared -Wl,-soname," + @libName
      end
    end

    alias :getConfigString :makeLinkerCallString


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
      linkCommand = makeLinkerCallString() + " -o " + @libFileName
      @dependencies.each do |dep|
        # we only want dependencies that provide an object file
        linkCommand += " " + dep.objectFileName if (dep.respond_to?(:objectFileName) and dep.objectFileName)
      end
      Makr.log.info("Building DynamicLibTask #{@name}\n\t" + linkCommand)
      successful = system(linkCommand)
      Makr.log.error("Error in DynamicLibTask #{@name}") if not successful
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
    libTask.addDependencies(taskCollection)
    build.defaultTask = libTask # set this as default task in build
    return libTask
  end




















  # This class constructs a static library. No special flags are needed as compared to DynamicLibTask regarding
  # the CompileTasks.
  class StaticLibTask < Task
    # special static lib thingies (see http://www.faqs.org/docs/Linux-HOWTO/Program-Library-HOWTO.html)
    # standard construction is: "ar rcs my_library.a file1.o file2.o ..."

    attr_reader    :libName  # basename of the lib to be build
    attr_reader    :libFileName  # path of the lib to be build (does not need to be absolute)


    # make a unique name
    def StaticLibTask.makeName(libName)
       "StaticLibTask__" + libName
    end


    def makeLinkerCallString() # "ar rcs" is default value
      if @config then
        Makr.log.debug("StaticLibTask " + @name + ": config name is: \"" + @config.name + "\"")
        @config = @build.getConfig(@@configName)
        callString = String.new
        if (not @config["linker"]) then
          Makr.log.warn("no linker command given, using default ar")
          callString = "ar rcs "
        else
          callString = @config["linker"] + " "
        end
        return callString
      else
        Makr.log.warn("no @config given, using bare linker ar")
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
        # we only want dependencies that provide an object file
        linkCommand += " " + dep.objectFileName if (dep.respond_to?(:objectFileName) and dep.objectFileName)
      end
      Makr.log.info("Building StaticLibTask \"#{name}\"\n\t" + linkCommand)
      successful = system(linkCommand)
      Makr.log.error("Error in StaticLibTask #{@name}") if not successful
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
    libTask.addDependencies(taskCollection)
    build.defaultTask = libTask # set this as default task in build
    return libTask
  end


















  # This class represents a task that builds a program binary made up from all dependencies that
  # define an objectFileName-member.
  class ProgramTask < Task

    attr_reader    :programName  # identifies the binary to be build, wants full path as usual


    # make a unique name for ProgramTasks out of the programName which is to be compiled
    # expects a Pathname or a String
    def ProgramTask.makeName(programName)
       "ProgramTask__" + programName
    end


    def makeLinkerCallString() # g++ is always default value
      if @config then
        Makr.log.debug("ProgramTask " + @name + ": config name is: \"" + @config.name + "\"")
        callString = String.new
        if (not @config["linker"]) then
          Makr.log.warn("no linker command given, using default g++")
          callString = "g++ "
        else
          callString = @config["linker"] + " "
        end
        # now add other flags and options
        callString += @config["linker.lFlags"]       + " " if @config["linker.lFlags"]
        callString += @config["linker.libPaths"]     + " " if @config["linker.libPaths"]
        callString += @config["linker.libs"]         + " " if @config["linker.libs"]
        callString += @config["linker.otherOptions"] + " " if @config["linker.otherOptions"]
        return callString
      else
        Makr.log.warn("no config given, using bare linker g++")
        return "g++ "
      end
    end

    alias :getConfigString :makeLinkerCallString


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

      Makr.log.debug("made ProgramTask with @name=\"" + @name + "\"")
    end


    def update()
      @state = nil # first set state to unsuccessful build

      # build compiler command and execute it
      linkCommand = makeLinkerCallString() + " -o " + @programName
      @dependencies.each do |dep|
        # we only want dependencies that provide an object file
        linkCommand += " " + dep.objectFileName if (dep.respond_to?(:objectFileName) and dep.objectFileName)
      end
      Makr.log.info("Building ProgramTask \"" + @name + "\"\n\t" + linkCommand)
      successful = system(linkCommand)
      Makr.log.error("Error in ProgramTask #{@name}") if not successful
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
    progTask.addDependencies(taskCollection)
    build.defaultTask = progTask # set this as default task in build
    return progTask
  end







  
end     # end of module makr ######################################################################################




