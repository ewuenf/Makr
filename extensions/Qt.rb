
# this extension itself depends on one of the mentioned toolchains
module Qt_Extension_Check
  exList = ["ToolChainLinuxGcc"]
  if not Makr.isAnyOfTheseExtensionsLoaded?(exList) then
    Makr.log.error( "Error on loading extension \"Qt\", needing one of the following extensions:\n" +
                    "\"" + exList.join("\", \"") + "\"\n\n\n"
                  )
    raise #we stop execution here
  end
end


module Makr






  # Represents a task executing the "moc" code generator from "Qt".
  class MocTask < Task

    # the path of the input and output file of the compilation
    attr_reader :fileName, :mocFileName


    # checks for presence of Q_OBJECT macro in file which indicates, that is needs to be processed by moc
    def MocTask.containsQ_OBJECTMacro?(fileName)
      IO.readlines(fileName).each do |line|
        return true if (line.strip == "Q_OBJECT")
      end
      return false
    end


    # make a unique name for a MocTask out of the given fileName
    def MocTask.makeName(fileName)
      "MocTask__" + fileName
    end


    # constructing the string to call the moc out of the given config (or default values)
    def makeMocCallString()
      callString = String.new
      if @config then
        Makr.log.debug("MocTask " + @name + ": config name is: \"" + @config.name + "\"")
        if @config["moc"].empty? then
          Makr.log.debug("MocTask " + @name + ": no moc binary given, using moc in path")
          callString = "moc "
        else
          callString = @config["moc"] + " "
        end
        callString += @config["moc.flags"] + " " if not @config["moc.flags"].empty? # add other options
      else
        Makr.log.debug("MocTask " + @name + ": no config given, using default bare moc")
        callString = "moc "
      end
      return callString
    end

    alias :getConfigString :makeMocCallString


    def makeMocFileName()
      # default pre- and suffix for generated moc file
      prefix = "" # default is no prefix to allow sort by name in file manager
      suffix = ".moc_gen.cpp"
      # check if user supplied other values via config
      if @config then
        prefix = @config["moc.filePrefix"] if (not @config["moc.filePrefix"].empty?)
        suffix = @config["moc.fileSuffix"] if (not @config["moc.fileSuffix"].empty?)
      end
      # double substitution of underscores to prevent name conflicts
      @build.buildPath + "/" + prefix + fileName.gsub('_', '__').gsub('/', '_').gsub('.', '_') + suffix
    end


    # The options accepted in the Config referenced by config could be "moc" and "moc.flags"
    # (see also function makeMocCallString() )
    def initialize(fileName, build, config = nil)
      @fileName = Makr.cleanPathName(fileName)
      # now we need a unique name for this task. As we're defining a FileTask as dependency to @fileName
      # and a FileTask on the @mocFileName to ensure a build of the target if it was deleted or
      # otherwise modified (whatever you can think of here), we need a unique name not related to these
      super(MocTask.makeName(@fileName), config)
      @build = build
      @mocFileName = makeMocFileName()

      # first we need a dep on the input file
      @inputFileDep = @build.getOrMakeNewTask(@fileName) {FileTask.new(@fileName)}
      addDependencyUnique(@inputFileDep)
      
      # now add a dep on the moc output file
      @mocTargetDep = @build.getOrMakeNewTask(@mocFileName) {FileTask.new(@mocFileName, false)}
      addDependencyUnique(@mocTargetDep)
      @targets = [@mocFileName]

      # now add another dep on the config
      @configDep = @build.getOrMakeNewTask(ConfigTask.makeName(@name)) {ConfigTask.new(ConfigTask.makeName(@name))}
      addDependencyUnique(@configDep)

      Makr.log.debug("made MocTask with @name=\"" + @name + "\"")
    end


    def update()
      @state = nil # first set state to unsuccessful build

      # construct compiler command and execute it
      mocCommand = makeMocCallString() + " -o " + @mocFileName + " " + @fileName
      
      # output is colorized using ANSI escape codes (see also http://stackoverflow.com/questions/1489183/colorized-ruby-output)
      Makr.log.info("Executing moc on \033[32m#{@fileName}\033[0m")
      Makr.log.debug("Executing moc in MocTask \033[32m#{@name}\033[0m\n\t" + mocCommand)

      successful = system(mocCommand)

      Makr.log.error("\033[31mErrors\033[0m executing moc on #{@fileName}") if not successful

      @mocTargetDep.update() # update file information on the compiled target in any case

      # indicate successful update by setting state string to preliminary concat string (set correctly in postUpdate)
      @state = concatStateOfDependencies() if successful 
    end


    # this task wants to be deleted if the file no longer contains the Q_OBJECT macro (TODO is this correct?)
    def mustBeDeleted?()
      return (not MocTask.containsQ_OBJECTMacro?(@fileName))
    end

  end








  # Produces a MocTask for every fileName given, if it does not exist and an additional CompileTask for the generated file.
  # All CompileTask objects get the compileTaskConfigName if given, all MocTasks get the mocTaskConfigName.
  class MocTaskGenerator

    def initialize(build, compileTaskConfig = nil, mocTaskConfig = nil)
      @build = build
      @mocTaskConfig = mocTaskConfig
      @compileTaskConfig = compileTaskConfig
    end


    def generate(fileName)
      # first check, if file has Q_OBJECT, otherwise we return no tasks
      return Array.new if not MocTask.containsQ_OBJECTMacro?(fileName)

      # Q_OBJECT contained, now go on
      fileName = Makr.cleanPathName(fileName)
      mocTaskName = MocTask.makeName(fileName)
      if not @build.hasTask?(mocTaskName) then
        mocTask = MocTask.new(fileName, @build, @mocTaskConfig)
        @build.addTask(mocTaskName, mocTask)
      end
      mocTask = @build.getTask(mocTaskName)
      # care for changed configName when config is from cache
      if mocTask.config != @mocTaskConfig then
        Makr.log.debug( "configName has changed in task " + mocTask.name + \
                       " compared to cached version, setting to new value: " + @mocTaskConfig.name)
        mocTask.config = @mocTaskConfig
      end
      tasks = [mocTask]
      # TODO make common code with CompileTaskGenerator for the following
      compileTaskName = CompileTask.makeName(mocTask.mocFileName)
      if not @build.hasTask?(compileTaskName) then
        compileTask = CompileTask.new(mocTask.mocFileName, @build, @compileTaskConfig, true, mocTask)
        @build.addTask(compileTaskName, compileTask)
      end
      compileTask = @build.getTask(compileTaskName)
      # care for changed configName when config is from cache
      if compileTask.config != @compileTaskConfig then
        Makr.log.debug( "configName has changed in task " + compileTask.name + \
                       " compared to cached version, setting to new value: " + @compileTaskConfig)
        compileTask.config = @compileTaskConfig
      end
      tasks.push(compileTask)
      @build.pushTaskToFileHash(fileName, tasks)
      return tasks
    end

  end









  ##################################  Uic things










  # Represents a task executing the "uic" code generator from "Qt".
  class UicTask < Task

    # input file
    attr_reader :fileName
    # output file
    attr_reader :uicFileName


    # make a unique name for a MocTask out of the given fileName
    def UicTask.makeName(uicFileName)
      "UicTask__" + uicFileName
    end


    # constructing the string to call the moc out of the given config (or default values)
    def makeUicCallString()
      callString = String.new
      if @config then
        Makr.log.debug("UicTask " + @name + ": config name is: \"" + @config.name + "\"")
        if (not @config["uic"].empty?) then
          Makr.log.debug("UicTask " + @name + ": no uic binary given, using uic in path")
          callString = "uic "
        else
          callString = @config["uic"] + " "
        end
        callString += @config["uic.flags"] + " " if @config["uic.flags"] # add other options
      else
        Makr.log.debug("UicTask " + @name + ": no config given, using default bare uic")
        callString = "uic "
      end
      return callString
    end

    alias :getConfigString :makeUicCallString


    # The options accepted in the Config referenced by config could be "moc" and "moc.flags"
    # (see also function makeMocCallString() )
    def initialize(fileName, build, config = nil)
      @fileName = Makr.cleanPathName(fileName)
      # now we need a unique name for this task, as we're defining a FileTask as dependency to @fileName
      super(UicTask.makeName(@fileName), config)
      @build = build

      @uicFileName = @fileName + ".h"  # use simple header file extension as it is included in other files

      # first we need a dep on the input file
      @inputFileDep = @build.getOrMakeNewTask(@fileName) {FileTask.new(@fileName)}
      addDependencyUnique(@inputFileDep)

      # now add a dep on the uic output file
      @uicTargetDep = @build.getOrMakeNewTask(@uicFileName) {FileTask.new(@uicFileName, false)}
      addDependencyUnique(@uicTargetDep)
      @targets = [@uicFileName]

      # now add another dep on the config
      @configDep = @build.getOrMakeNewTask(ConfigTask.makeName(@name)) {ConfigTask.new(ConfigTask.makeName(@name))}
      addDependencyUnique(@configDep)

      Makr.log.debug("made UicTask with @name=\"" + @name + "\"")
    end


    def update()
      @state = nil # first set state to unsuccessful build

      # construct compiler command and execute it
      uicCommand = makeUicCallString() + " -o " + @uicFileName + " " + @fileName

      # output is colorized using ANSI escape codes (see also http://stackoverflow.com/questions/1489183/colorized-ruby-output)
      Makr.log.info("Executing uic on \033[32m#{@fileName}\033[0m")
      Makr.log.debug("Executing uic in UicTask \033[32m#{@name}\033[0m\n\t" + uicCommand)

      successful = system(uicCommand)

      Makr.log.error("\033[31mErrors\033[0m executing uic on #{@fileName}") if not successful

      @uicTargetDep.update() # update file information on the compiled target in any case

      # indicate successful update by setting state string to preliminary concat string (set correctly in postUpdate)
      @state = concatStateOfDependencies() if successful 
    end


    # this task wants to be deleted if the file no longer contains the Q_OBJECT macro (TODO is this correct?)
    def mustBeDeleted?()
      return (not File.exists?(@fileName))
    end

  end


















  # Produces a UicTask for every fileName given
  class UicTaskGenerator

    def initialize(build, uicTaskConfig = nil)
      @build = build
      @uicTaskConfig = uicTaskConfig
    end


    def generate(fileName)
      return Array.new if not fileName.rindex(".ui")  # TODO: maybe we want to check for the xml code inside

      fileName = Makr.cleanPathName(fileName)
      uicTaskName = UicTask.makeName(fileName)
      if not @build.hasTask?(uicTaskName) then
        uicTask = UicTask.new(fileName, @build, @uicTaskConfig)
        @build.addTask(uicTaskName, uicTask)
      end
      uicTask = @build.getTask(uicTaskName)
      # care for changed configName when config is from cache
      if uicTask.config != @uicTaskConfig then
        Makr.log.debug( "configName has changed in task " + uicTask.name + \
                       " compared to cached version, setting to new value: " + @uicTaskConfig.name)
        uicTask.config = @uicTaskConfig
      end
      tasks = [uicTask]
      @build.pushTaskToFileHash(fileName, tasks)
      return tasks
    end

  end









end     # end of module makr ######################################################################################



