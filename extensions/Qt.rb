

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
        if (not @config["moc"]) then
          Makr.log.warn("MocTask " + @name + ": no moc binary given, using moc in path")
          callString = "moc "
        else
          callString = @config["moc"] + " "
        end
        callString += @config["moc.flags"] + " " if @config["moc.flags"] # add other options
      else
        Makr.log.warn("MocTask " + @name + ": no config given, using default bare moc")
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
        prefix = @config["moc.filePrefix"] if (@config["moc.filePrefix"])
        suffix = @config["moc.fileSuffix"] if (@config["moc.fileSuffix"])
      end
      @build.buildPath + "/" + prefix + fileName.gsub('/', '_').gsub('.', '_') + suffix
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
      if not @build.hasTask?(@fileName) then
        @inputFileDep = FileTask.new(@fileName)
        @build.addTask(@fileName, @inputFileDep)
      else
        @inputFileDep = @build.getTask(@fileName)
      end
      addDependency(@inputFileDep)
      # now add a dep on the moc output file
      if not @build.hasTask?(@mocFileName) then
        @mocTargetDep = FileTask.new(@mocFileName, false)
        @build.addTask(@mocFileName, @mocTargetDep)
      else
        @mocTargetDep = @build.getTask(@mocFileName)
      end
      addDependency(@mocTargetDep)
      # now add another dep on the config
      @configTaskName = ConfigTask.makeName(@name)
      if not @build.hasTask?(@configTaskName) then
        @configDep = ConfigTask.new(@configTaskName)
        @build.addTask(@configTaskName, @configDep)
      else
        @configDep = @build.getTask(@configTaskName)
      end
      addDependency(@configDep)

      Makr.log.debug("made MocTask with @name=\"" + @name + "\"")
    end


    def update()
      # we first delete the target file so that upon miscompilation at least the @mocTargetDep wants an update
      # the next time we run this script so that we can guarantee an update to the last state of the dependencies
      File.delete @mocFileName rescue nil
      @mocTargetDep.update() # we need to update the dep after deletion

      # construct compiler command and execute it
      mocCommand = makeMocCallString() + " -o " + @mocFileName + " " + @fileName
      Makr.log.info("Executing moc in MocTask: \"" + @name + "\"\n\t" + mocCommand)
      successful = system(mocCommand)
      if not successful then
        Makr.log.fatal("moc error, exiting build process\n\n\n")
        Makr.abortBuild()
      end
      return @mocTargetDep.update() # we call this to update file information on the compiled target
        # additionally this returns true, if the target was changed, and false otherwise what is what
        # we want to propagate
    end


    # this task wants to be deleted if the file no longer contains the Q_OBJECT macro (TODO is this correct?)
    def mustBeDeleted?()
      return (not MocTask.containsQ_OBJECTMacro?(@fileName))
    end


    # remove possibly remaining generated mocced file before deletion
    def cleanupBeforeDeletion()
      File.delete @mocFileName  rescue nil
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
      Makr.cleanPathName(fileName)
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
      # now fill fileHash
      @build.fileHash[fileName] ||= Array.new
      @build.fileHash[fileName].concat(tasks)
      @build.fileHash[fileName].uniq!
      return tasks
    end

  end









end     # end of module makr ######################################################################################



