#!/usr/bin/ruby


# This is my own home-brewn ruby-based build tool.
# I hereby name it "makr" and it will read "Makrfiles", uenf!
#
# Documentation is sparse as source is short and readable and a number
# of examples are/willbe provided.
#
#
# Some remarks: In general, we want relative paths, so that development dirs can be moved without whoes. 
#               The user may still prefer absolute paths (and use them), but the script tries to make no assumptions.
#               We also make no assumptions on the command lines arguments given, the user is free to parse
#               his own parameter set (using OptionParser from the stdlib for example).
#               The only thing this script does is loading the Makrfile.rb and providing
#               the command line argument in the ScriptArguments stack. The name "Makrfile.rb" is hardcoded, but
#               the user may be free to use this file to load some other file and execute it depending on the
#               parameters given on the command line.
#               During update, the task graph is not modified (only a convention, not enforced), so that programming
#               the multithreaded update is much more simplified.


require 'ftools'
require 'find'
require 'thread'
require 'md5'
require 'logger'
require 'stringio'





module Makr








  # slightly modified from https://github.com/fizx/thread_pool #########################################
  class ThreadPool
    class Executor
      attr_reader :active

      def initialize(queue, mutex)
        @thread = Thread.new do
          loop do
            mutex.synchronize { @tuple = queue.shift }
            if @tuple
              args, block = @tuple
              @active = true
              begin
                block.call(*args)
              rescue Exception => e
                error e.message
                error e.backtrace.join("\n")
              end
              block.complete = true
            else
              @active = false
              sleep 0.01
            end
          end
        end
      end

      def close
        @thread.exit
      end
    end

    attr_accessor :queue_limit

    # Initialize with count threads to run (if count is not given, all processors of the system will be used)
    def initialize(count = nil, queue_limit = 0)
      @mutex = Mutex.new
      @executors = []
      @queue = []
      @queue_limit = queue_limit
      @count = (count)?count:`grep -c processor /proc/cpuinfo`.to_i  # TODO works only on linux (and maybe most unixes)
      @count.times { @executors << Executor.new(@queue, @mutex) }
    end

    # Runs the block at some time in the near future
    def execute(*args, &block)
      init_completable(block)

      if @queue_limit > 0
        sleep 0.01 until @queue.size < @queue_limit
      end

      @mutex.synchronize do
        @queue << [args, block]
      end
    end

    # Runs the block at some time in the near future, and blocks until complete
    def synchronous_execute(*args, &block)
      execute(*args, &block)
      sleep 0.01 until block.complete?
    end

    # Size of the task queue
    def waiting
      @queue.size
    end

    # Size of the thread pool
    def size
      @count
    end

    # Kills all threads
    def close
      @executors.each {|e| e.close }
    end

    # Sleeps and blocks until the task queue is finished executing
    def join
      while (not (@queue.empty? and @executors.all?{|e| !e.active}))
        sleep 0.01
      end      
    end

  protected
    def init_completable(block)
      block.extend(Completable)
      block.complete = false
    end

    module Completable
      def complete=(val)
        @complete = val
      end

      def complete?
        !!@complete
      end
    end
  end

  # end of thread pool implementation ########################################################################################
  # own methods / classes follow







  # logging 
  @log = Logger.new(STDOUT)
  def Makr.log()
    @log
  end




  # central aborting method. TODO the concept does not seem final
  def Makr.abortBuild()
    Makr.log.fatal("Aborting build process.")
    UpdateTraverser.abortUpdate = true # cooperative abort
    # Kernel.exit! 1  did not work as expected
  end




  # a helper function to clean a pathName fed into the function coming out with no slashes at the end
  def Makr.cleanPathName(pathName)
    if pathName.empty? then
      Makr.log.warn("Trying to clean empty pathName!")
      return pathName
    end
    # pathName.strip! # remove white space in front and at the end (could be problematic)
    pathName.chop! unless (pathName.rindex("/") != (pathName.size() - 1))  # remove slashes at the end
    return pathName
  end





  # Hierarchical configuration management (Config instances have a parent) resembling a hash. Asking for a key will walk up
  # in hierarchy, until key is found or a new entry needs to be created in root config.
  # Hierarchy is with single parent. Regarding construction and usage of configs see class Build or examples.
  # Keys could follow dot-seperated naming rules like "my.perfect.config.key". The hash is saved in a human-readable
  # form in a file in the build directory (could even be edited by hand).
  class Config

    attr_reader   :name, :parent, :childs
    

    def initialize(name, parent = nil) # parent is a config, too
      @name = name
      setParent(parent)
      @hash = Hash.new
      @childs = Array.new
    end


    def setParent(parent)
      unparent()
      @parent =  parent
      @parent.addChild(self) if @parent
    end


    def unparent() # kind of dtor
      @parent.removeChild(self) if @parent
      @parent = nil
    end

    
    def clear()
      @hash.clear()
    end

    
    # copies the complete parents (and parents parents) (and parents parents parents) keyz to this config or only the key given
    def copyParent(key = nil)
      return if not @parent
      if key then
        tmp = @parent[key]
        @hash[key] = tmp if tmp
      else
        # collect the complete hash from all parents
        hash = Hash.new
        @hash = collectHash(hash)
      end
    end


    # collects the complete key-value pairs of this Config and its parents into hash
    def collectHash(hash)
      # duplicate keyz are resolved in favor of the argument of the merge!-call, which is what we want here
      # (this way childs overwrite parents keys)
      hash.merge!(@parent.collectHash(hash))  if @parent
      hash.merge!(@hash)
    end
    

    # adds value to the keys value if it is not already included (useful for adding compiler options etc)
    def addUnique(key, value)
      curVal = @hash[key]
      if curVal then
        curVal += value if not curVal.include?(value)
      else
        @hash[key] = value
      end
    end


    # convenience mix function of copyParent and addUnique
    def copyAddUnique(key, value)
      copyParent(key)
      addUnique(key, value)
    end


    # accessor function, like hash. See examples of Config usage
    def [](key)
      if @hash.has_key?(key) or not @parent then
        # we have the key and return it or we have no parent and return nil (the hash returns nil if it hasnt got the key)
        return @hash[key]
      else # case: hash has not got the key and we have a parent
        # the following will either return a value to the key found in one of the recursive parents or it will
        # return nil, as the key was not found (comparable to a standard hash behaviour)
        return @parent[key]
      end
    end


    # accessor function, like hash. See examples of Config usage
    def []=(key, value)
      # we always assign, regardless of the parent, which may have the same key, as the keys
      # in this class override the parents keys (see also [](key))
      @hash[key] = value
    end


    # serializes this Config (without parents values, but mentioning parent name) into a string
    def to_s
      stringio = StringIO.new
      output(stringio)
      stringio.string
    end


    # serializes this Config (without parents values, but mentioning parent name) into the given io object
    def output(io)
      io << "  start " << @name << "\n"
      if @parent then
        io << "  parent " << @parent.name << "\n"
      end
      sortedHash = @hash.sort
      sortedHash.each do |entry|
        io << "    \"" << entry[0] << "\"=\"" << entry[1] << "\"\n"
      end
      io << "  end " << @name << "\n\n"
    end


    # parses the Config from an array of strings (lines) starting from line lineIndex
    # returns (Boolean,Integer,String) with the meaning:
    # (parsing went well, last line visited, parent name)
    def input(lines, lineIndex = 0)
      foundStart = false
      parentName = nil
      for i in (lineIndex..(lines.size() - 1)) do
        line = lines[i]      # get the current line from array,
        line.strip!          # then remove any whitespace and
        next if line.empty?  # ignore newlines
        
        # at first, we need to have a start marker (with the name of the Config)
        if not foundStart then
          if not line.index("start") then
            Makr.log.error("Config parse error at line nr " + i.to_s)
            return false, i, parentName
          else
            @name = line[("start ".length)..-1]
            foundStart = true
            next
          end
        end
        # then we check for a parent
        if line.index("parent") == 0 then
          parentName = line["parent ".length..-1]
          next
        end
        # if we find the end marker, we can return true (we dont care about the end matching @name)
        if line.index("end") == 0 then
          return true, i, parentName
        end
        # if none of the above match, we have a normal line and parse the key-value-pair and add it to the hash
        splitArr = line.split("\"=\"")
        if splitArr.size < 2 then
          Makr.log.error("Config parse error at line nr " + i.to_s)
          return false, i, parentName
        end
        @hash[(splitArr[0])[1..-1]] = (splitArr[-1])[0..-2] # skip the character " at the start and end
      end
      # gone through all lines, so we return, if start was found anyway and we expected end somewhere
      return (not foundStart), i, parentName
    end


  protected # comparable to private in C++

    def addChild(config)
      @childs.push(config)
    end


    def removeChild(config)
      @childs.delete(config)
    end


  end



  
  

  # Convenience class related to Config adding compiler flags (Config key "compiler.cFlags") and
  # options related to a lib using pkg-config.
  class PkgConfig
  
    def PkgConfig.addCFlags(config, pkgName)
      config.addUnique("compiler.cFlags", " " + (`pkg-config --cflags #{pkgName}`).strip!)
    end
    
    
    def PkgConfig.addLibs(config, pkgName, static = false)
      command = "pkg-config --libs " + ((static)? " --static ":"") + pkgName
      config.addUnique("linker.lFlags", " " + (`#{command}`).strip!)
    end

    
    def PkgConfig.getAllLibs()
      list = `pkg-config --list-all`
      hash = Hash.new
      list.each_line do |line|
        splitArr = line.split
        hash[splitArr[0]] = splitArr[1..(splitArr.size - 1)].join(" ")
      end
      return hash
    end
  end


  
  
  
  
  

  # Basic class and concept representing a node in the dependency tree and any type of action that
  # needs to be performed (such as a versioning system update or somethink else). A possible configuration
  # of the task is only referred to by name as I did not want linked data structures, that would be
  # saved all together upon marshalling in class build. Config class is different.
  class Task

    # dependencies are of course tasks this task depends on an additionally we have the array of
    # dependantTask that depend on this task (double-linked graph structure)
    attr_reader :name, :dependencies, :dependantTasks
    # for reading and setting the Config name
    attr_accessor :configName
    # these are used by the multi-threaded UpdateTraverser
    attr_accessor :mutex, :updateMark, :dependenciesUpdatedCount, :dependencyWasUpdated


    # name must be unique within a build (see class Build)!
    def initialize(name)
      @name = name
      @dependencies = Array.new
      @dependantTasks = Array.new

      # regarding the meaning of these see class UpdateTraverser
      @mutex = Mutex.new
      @updateMark = false
      @dependenciesUpdatedCount = 0
      @dependencyWasUpdated = false
    end

    
    def addDependency(otherTask)
      if(@dependencies.index(otherTask) == nil)
        @dependencies.push(otherTask)
        otherTask.dependantTasks.push(self)
      end
      # we dont do anything if a task wants to be added twice, they are unique, maybe we should log this
    end


    # convenience function for adding a plethora of tasks
    def addDependencies(otherTasks)
      otherTasks.each {|task| addDependency(task)}
    end


    def removeDependency(otherTask)
      if(@dependencies.index(otherTask) != nil)
        otherTask.dependantTasks.delete(self)
        @dependencies.delete(otherTask)
      else
        raise "[makr] Trying to remove a non-existant dependency!" # here we definitely raise an exception
      end
    end

    
    def clearDependencies()
      Makr.log.debug("clearing deps in: " + @name)
      while not @dependencies.empty?
        removeDependency(@dependencies.first)
      end
    end

    
    def clearDependantTasks()
      while not @dependantTasks.empty?
        @dependantTasks.first.removeDependency(self)  # this deletes @dependantTasks.first implicitely (see above)
      end
    end

    
    def clearAll()
      clearDependencies()
      clearDependantTasks()
    end

    
    # Every subclass should provide an "update()" function, that returns wether the target of the task is updated/changed.
    # The task graph itself should be unchanged during update. Use function postUpdate() for this purpose.
    def update() 
      false
    end

    
    # The method postUpdate() is called after all tasks have been "update()"d. Task instances need to register for the
    # postUpdate()-call during the update()-call using "Build::registerPostUpdate(self)". While update() is called in
    # parallel on the task graph and should not modify the graph, this function is called on all registered tasks in a
    # single thread, so that no issues with multi-threading can occur. As this obviously is a bottleneck, the function
    # should only be used if it is absolutely necessary to modify the task structure upon updating procedure.
    # This behaviour might change in future revisions of this tool, as the author or someone else might get better
    # concepts out of his brain.
    def postUpdate()
    end

    
    # can be impletemented by subclasses indicating that this task is no longer valid due to a circumstance such as
    # a missing file
    def mustBeDeleted?()
      false
    end


    # kind of debugging to_s function
    def printDependencies(prefix)
      Makr.log.info(prefix + @name + " deps size: " + @dependencies.size.to_s)
      @dependencies.each do |dep|
        dep.printDependencies(prefix + "  ")
      end
    end
    

    def cleanupBeforeDeletion()  # interface mainly for tasks generating targets (removing these)
    end

    
  end





  



  
  # Represents simple and basic dependencies on a files (could be input or output). set class variable FileTask.useFileHash to
  # true (default is false) to check file change by md5-summing (is a costly operation)
  class FileTask < Task

    # this variable states, if file hashes should be used to identify changed files (which can be a costly operation)
    @@useFileHash = false
    def FileTask.useFileHash
      @@useFileHash
    end
    def FileTask.useFileHash=(arg)
      @@useFileHash = arg
    end


    attr_reader :fileName, :time, :size, :fileHash, :missingFileIsError

    
    # the boolean argument missingFileIsError can be used to indicate, if an update is necessary, if file is missing 
    # (which is the "false" case) or if it is an error and the build should abort. In other words: if missingFileIsError
    # is false, a missing file just means that the update function will return true. This can be used for targets of
    # the build process (see also class CompileTask for a usage example), to indicate a target that needs to be produced.
    def initialize(fileName, missingFileIsError = true)
      @fileName = Makr.cleanPathName(fileName)
      super(@fileName)
      # all file attribs stay uninitialized, so that first call to update returns true
      @time = @size = @fileHash = String.new
      @missingFileIsError = missingFileIsError
      Makr.log.debug("made file task with @fileName=\"" + @fileName + "\"")
    end

    
    def mustBeDeleted?()
      if (not File.file?(@fileName)) and (@missingFileIsError) then
          Makr.log.info("mustBeDeleted?() is true for missing file: " + @fileName)
          return true
      end
      return false
    end

    
    def update()
      if (not File.file?(@fileName)) then
        if @missingFileIsError then
          Makr.log.fatal("file " + @fileName + "  is unexpectedly missing!\n\n")
          Makr.abortBuild()
        end
        Makr.log.info("file " + @fileName + " is missing, so update() in FileTask is true.")
        return true
      end
      stat = File.stat(@fileName);
      retValue = false
      if (@time != stat.mtime) then
        @time = stat.mtime
        retValue = true
      end
      if (@size != stat.size) then
        @size = stat.size
        retValue = true
      end
      if @@useFileHash then
        curHash = MD5.new(open(@fileName, 'rb').read).hexdigest
        if(@fileHash != curHash)
          @fileHash = curHash
          retValue = true
        end
      end
      if retValue then
        Makr.log.info("Changed: " + @fileName)
      end
      return retValue
    end

    
  end





  


  

  # This class represents the dependency on changed strings in a Config, it is used for example in CompileTask
  class ConfigTask < Task

    # make a unique name for CompileTasks out of the fileName which is to be compiled
    def ConfigTask.makeName(name)
      "ConfigTask__" + name
    end

    
    def initialize(name)
      super
      @storedConfigString = String.new
    end

    
    def update()
      if not dependantTasks.first then
        raise "[makr] ConfigTask \"" + name + "\" does not have a dependant task, but needs one!"
      end
      currentConfigString = dependantTasks.first.getConfigString()
      retVal = (@storedConfigString != currentConfigString)
      @storedConfigString = currentConfigString
      retVal
    end
    
  end








  
  

  # Represents a standard compiled source unit that has dependencies to included files (and any deps that a user may specify).
  # The input files are dependencies on FileTasks including the source itself. Another dependency exists on the
  # target object file, so that the task rebuilds, if that file was deleted or modified otherwise. Also the
  # task has a dependency on the Config object that contains the compiler options etc. so that a change in these
  # also triggers recompilation (see also ConfigTask). The variable CompileTask.checkOnlyUserHeaders controls, wether
  # dependency checking is extended to system header files or not (the former is more costly, default is not to do
  # this).
  class CompileTask < Task


    # builds up the string used for calling the compiler out of the given Config (or default values),
    # the dependencies are not included (this is done in update)
    def makeCompilerCallString() # g++ is the general default value
      if @configName then
        Makr.log.debug("CompileTask " + @name + ": config name is: \"" + @configName + "\"")
        config = @build.getConfig(@configName)
        callString = String.new
        if (not config["compiler"]) then
          Makr.log.warn("CompileTask " + @name + ": no compiler given, using default g++")
          callString = "g++ "
        else
          callString = config["compiler"] + " "
        end
        # now add additionyl flags and options
        if config["compiler.cFlags"] then
          callString += config["compiler.cFlags"] + " "
        end
        if config["compiler.defines"] then
          callString += config["compiler.defines"] + " "
        end
        if config["compiler.includePaths"] then
          callString += config["compiler.includePaths"] + " "
        end
        if config["compiler.otherOptions"] then
          callString += config["compiler.otherOptions"] + " "
        end
        return callString
      else
        Makr.log.warn("CompileTask " + @name + ": no config given, using bare g++")
        return "g++ "
      end
    end

    alias :getConfigString :makeCompilerCallString


    # this variable influences dependency checking by the compiler ("-M" or "-MM" option)
    @@checkOnlyUserHeaders = true
    def CompileTask.checkOnlyUserHeaders
      @@checkOnlyUserHeaders
    end
    def CompileTask.checkOnlyUserHeaders=(arg)
      @@checkOnlyUserHeaders = arg
    end


    # make a unique name for CompileTasks out of the fileName which is to be compiled
    def CompileTask.makeName(fileName)
      "CompileTask__" + fileName
    end


    # we strive to make a unique name even if source files with identical names exist by
    # taking the whole path and replacing directory seperators with underscores
    def makeObjectFileName(fileName)
      @build.buildPath + "/" + fileName.gsub('/', '_').gsub('.', '_') + ".o"
    end


    # the path of the input and output file of the compilation
    attr_reader :fileName, :objectFileName


    # arguments: fileName contains the file to be compiled, build references the Build object containing the tasks
    # (including this one), configName is the name of the optional Config, fileIsGenerated specifies that
    # the file to be compiled is generated (for example by the moc from Qt). If fileIsGenerated is true, the
    # last argument must contain the task that generates it to add a dependency.
    def initialize(fileName, build, configName, fileIsGenerated = false, generatorTask = nil)
      @fileName = Makr.cleanPathName(fileName)
      # now we need a unique name for this task. As we're defining a FileTask as dependency to fileName
      # and a FileTask on the @objectFileName to ensure a build of the target if it was deleted or
      # otherwise modified (whatever you can think of here), we need a unique name not related to these
      super(CompileTask.makeName(@fileName))
      @build = build
      @configName = configName

      # first construct a dependency on the file itself, if it isnt generated
      # (we dont add dependencies yet, as they get added upon automatic dependency generation in
      # the function buildDependencies())
      @fileIsGenerated = fileIsGenerated
      @generatorTask = generatorTask
      if not @fileIsGenerated then
        if not @build.hasTask?(@fileName) then
          @compileFileDep = FileTask.new(@fileName)
          @build.addTask(@fileName, @compileFileDep)
        else
          @compileFileDep = @build.getTask(@fileName)
        end
      end

      # construct a dependency task on the target object file
      @objectFileName = makeObjectFileName(fileName)
      if not @build.hasTask?(@objectFileName) then
        @compileTarget = FileTask.new(@objectFileName, false)
        @build.addTask(@objectFileName, @compileTarget)
      else
        @compileTarget = @build.getTask(@objectFileName)
      end

      # construct a dependency task on the configuration
      @configTaskName = ConfigTask.makeName(@name)
      if not @build.hasTask?(@configTaskName) then
        @configTask = ConfigTask.new(@configTaskName)
        @build.addTask(@configTaskName, @configTask)
      else
        @configTask = @build.getTask(@configTaskName)
      end

      # the following first deletes all deps and then constructs them including tasks constructed above
      getDepsStringArrayFromCompiler()
      buildDependencies()

      Makr.log.debug("made CompileTask with @name=\"" + @name + "\"") # debug feedback
    end


    # calls compiler with complete configuration options to automatically generate a list of dependency files
    # the list is parsed in buildDependencies()
    # Parsing is seperated from dependency generation because during the update step we also check
    # dependencies but do no rebuild them as the tree should not be changed during multi-threaded update
    def getDepsStringArrayFromCompiler()
      # always clear input lines upon call
      @dependencyLines = Array.new
      # then check, if we need to to
      return if (@fileIsGenerated and (not File.file?(@fileName)))
      # system headers are excluded using compiler option "-MM", else "-M"
      depCommand = makeCompilerCallString() + ((@@checkOnlyUserHeaders)?" -MM ":" -M ") + @fileName
      Makr.log.info("Executing compiler to check for dependencies in CompileTask: \"" + @name + "\"\n\t" + depCommand)
      compilerPipe = IO.popen(depCommand)  # in ruby >= 1.9.2 we could use Open3.capture2(...) for this purpose
      @dependencyLines = compilerPipe.readlines
      if @dependencyLines.empty? then
        Makr.log.fatal( "error in CompileTask for file \"" + @fileName + \
                        "\" making dependencies failed, check file for syntax errors!")
        Makr.abortBuild()
      end
    end


    # parses the dependency files generated by the compiler in getDepsStringArrayFromCompiler().
    # Parsing is seperated from dependency generation because during the update step we also check
    # dependencies but do no rebuild them as the tree should not be changed during multi-threaded update
    def buildDependencies()
      clearDependencies()
      dependencyFiles = Array.new
      @dependencyLines.each do |depLine|
        depLine.strip! # remove white space and newlines
        if depLine.include?('\\') then # remove backslash on each line, if present
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
        next if (depFile == @fileName)
        if @build.hasTask?(depFile) then
          task = @build.getTask(depFile)
          if not @dependencies.include?(task)
            addDependency(task)
          end
        else
          task = FileTask.new(depFile)
          @build.addTask(depFile, task)
          addDependency(task) # dependencies cannot contain task if everything is coded right
        end
      end
      # now we also add the constructed dependencies again as we cleared all deps in the beginning
      addDependency(@compileFileDep) if not @fileIsGenerated
      addDependency(@compileTarget)
      addDependency(@configTask)
      addDependency(@generatorTask) if @fileIsGenerated
    end


    def update()
      # we do not modify task structure on update and defer this to the postUpdate call like good little children
      @build.registerPostUpdate(self)
      # we first execute the compiler to deliver an update on the dependent includes. We could do this
      # in postUpdate, too, but we assume this to be faster, as the files should be in OS cache afterwards and
      # compilation (the next step) should be faster
      getDepsStringArrayFromCompiler()
      # construct compiler command and execute it
      compileCommand = makeCompilerCallString() + " -c " + @fileName + " -o " + @objectFileName
      Makr.log.info("CompileTask " + @name + ": Executing compiler\n\t" + compileCommand)
      successful = system(compileCommand)
      if not successful then
        Makr.log.fatal("CompileTask " + @name + ": compile error, exiting build process\n#####################\n\n")
        Makr.abortBuild()
        return false
      end
      return @compileTarget.update() # we call this to update file information on the compiled target
        # additionally this return true, if the target was changed, and false otherwise what is what
        # we want to propagate
    end


    def postUpdate()
      buildDependencies()  # assuming we have called the compiler already in update giving us the deps strings
    end


    # before this task gets deleted, we remove the object file
    def cleanupBeforeDeletion()
      system("rm -f " + @objectFileName)
    end

  end










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
      if @configName then
        Makr.log.debug("MocTask " + @name + ": config name is: \"" + @configName + "\"")
        config = @build.getConfig(@configName)
        if (not config["moc"]) then
          Makr.log.warn("MocTask " + @name + ": no moc binary given, using moc in path")
          callString = "moc "
        else
          callString = config["moc"] + " "
        end
        if config["moc.flags"] then
          callString += config["moc.flags"] + " "
        end
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
      if @configName then
        config = @build.getConfig(@configName)
        prefix = config["moc.filePrefix"] if (config["moc.filePrefix"])
        suffix = config["moc.fileSuffix"] if (config["moc.fileSuffix"])
      end
      @build.buildPath + "/" + prefix + fileName.gsub('/', '_').gsub('.', '_') + suffix
    end


    # build contains the global configuration, see Build.globalConfig and class Config
    def initialize(fileName, build, configName)
      @fileName = Makr.cleanPathName(fileName)
      # now we need a unique name for this task. As we're defining a FileTask as dependency to @fileName
      # and a FileTask on the @mocFileName to ensure a build of the target if it was deleted or
      # otherwise modified (whatever you can think of here), we need a unique name not related to these
      super(MocTask.makeName(@fileName))
      @build = build
      @configName = configName
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
      # construct compiler command and execute it
      mocCommand = makeMocCallString() + " -o " + @mocFileName + " " + @fileName
      Makr.log.info("Executing moc in MocTask: \"" + @name + "\"\n\t" + mocCommand)
      successful = system(mocCommand)
      if not successful then
        Makr.log.fatal("moc error, exiting build process\n\n\n")
        Makr.abortBuild()
      end
      @mocTargetDep.update() # we call this to update file information on the compiled target
      return true # right now, we are always true (we could check for target equivalence or something else
                  # and then return false in case the target didnt change (based on file hash))
    end


    # this task wants to be deleted if the file no longer contains the Q_OBJECT macro (TODO is this correct?)
    def mustBeDeleted?()
      return (not MocTask.containsQ_OBJECTMacro?(@fileName))
    end


    # remove possibly remaining generated mocced file before deletion
    def cleanupBeforeDeletion()
      system("rm -f " + @mocFileName)
    end

  end









  


  # creating a dynamic lib requires compiling the object files with -fPIC flag!!!!!!!!!!!!! #############
  class DynamicLibTask < Task

    # special dynamic lib thingies (see http://www.faqs.org/docs/Linux-HOWTO/Program-Library-HOWTO.html)


    attr_reader    :libName  # basename of the lib to be build
    attr_reader    :libPath  # full path of the lib to be build (but not necessarily absolute path, depends on user)


    # make a unique name
    def DynamicLibTask.makeName(libName)
       "DynamicLibTask__" + libName
    end


    def checkDependencyTasksForPIC()
      @dependencies.each do |dep|
        if dep.kind_of?(CompileTask) then
          raise "[makr] DynamicLibTask wants configName in dependency CompileTask" + dep.name + "!" if not dep.configName
          config = @build.getConfig(dep.configName)
          if (not (config["compiler.cFlags"].include?("-fPIC") or config["compiler.cFlags"].include?("-fpic"))) then
            raise "[makr] DynamicLibTask wants -fPIC or -fpic in config[\"compiler.cFlags\"] of dependency CompileTasks!"
          end
        end
      end
    end


    
    def makeLinkerCallString() # g++ is always default value
      if @configName then
        Makr.log.debug("config name is: \"" + @configName + "\"")
        config = @build.getConfig(@configName)
        callString = String.new
        if (not config["linker"]) then
          Makr.log.warn("no linker command given, using default g++")
          callString = "g++ "
        else
          callString = config["linker"] + " "
        end
        # now add other flags and options
        if config["linker.lFlags"] then
          callString += config["linker.lFlags"] + " "
        end
        if config["linker.libPaths"] then
          callString += config["linker.libPaths"] + " "
        end
        if config["linker.libs"] then
          callString += config["linker.libs"] + " "
        end
        if config["linker.otherOptions"] then
          callString += config["linker.otherOptions"] + " "
        end
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


    # libPath should be the complete path (absolute or relative) of the library with all standard fuss, like "libxy.so.1.2.3"
    # (if you want a different soname for the lib, pass it as option with the config identified by configName)
    def initialize(libPath, build, configName)
      @libPath = Makr.cleanPathName(libPath)
      @libName = File.basename(@libPath)
      super(DynamicLibTask.makeName(@libPath))
      @build = build
      @configName = configName

      # we need a dep on the lib target
      if not @build.hasTask?(@libPath) then
        @targetFileTask = FileTask.new(@libPath, false)
        @build.addTask(@libPath, @targetFileTask)
      else
        @targetFileTask = @build.getTask(@libPath)
      end
      addDependency(@targetFileTask)
      # now add another dependency task on the config
      @configTaskName = ConfigTask.makeName(@libPath)
      if not @build.hasTask?(@configTaskName) then
        @configTask = ConfigTask.new(@configTaskName)
        @build.addTask(@configTaskName, @configTask)
      else
        @configTask = @build.getTask(@configTaskName)
      end
      addDependency(@configTask)

      Makr.log.debug("made DynamicLibTask with @name=\"" + @name + "\"")
    end


    def update()
      # we always check for properly setup dependencies
      checkDependencyTasksForPIC()
      # build compiler command and execute it
      linkCommand = makeLinkerCallString() + " -o " + @libPath
      @dependencies.each do |dep|
        # we only want dependencies that provide an object file
        if dep.instance_variable_defined?("@objectFileName") then
          linkCommand += " " + dep.objectFileName
        end
      end
      Makr.log.info("Building DynamicLibTask \"" + @name + "\"\n\t" + linkCommand)
      successful = system(linkCommand)
      if not successful then
        Makr.log.fatal("linker error, exiting build process\n\n\n")
        Makr.abortBuild()
      end
      @targetFileTask.update() # we call this to update file information on the compiled target
      return true # we could check here for target change like proposed in CompileTask.update
    end


    def cleanupBeforeDeletion()
      system("rm -f " + @libPath)
    end
  end





  
  def Makr.makeDynamicLib(libFileName, build, taskCollection, libConfig = nil)
    Makr.cleanPathName(libFileName)
    libTaskName = DynamicLibTask.makeName(libFileName)
    if not build.hasTask?(libTaskName) then
      build.addTask(libTaskName, DynamicLibTask.new(libFileName, build, libConfig))
    end
    libTask = build.getTask(libTaskName)
    libTask.addDependencies(taskCollection)
    build.defaultTask = libTask # set this as default task in build
    return libTask
  end

















  


  
  class StaticLibTask < Task
    # special static lib thingies (see http://www.faqs.org/docs/Linux-HOWTO/Program-Library-HOWTO.html)
    # standard construction is: "ar rcs my_library.a file1.o file2.o ..."

    attr_reader    :libName  # basename of the lib to be build
    attr_reader    :libPath  # full path of the lib to be build (but not necessarily absolute path, depends on user)


    # make a unique name
    def StaticLibTask.makeName(libName)
       "StaticLibTask__" + libName
    end


    def makeLinkerCallString() # "ar rcs" is default value
      if @configName then
        Makr.log.debug("config name is: \"" + @configName + "\"")
        config = @build.getConfig(@configName)
        callString = String.new
        if (not config["linker"]) then
          Makr.log.warn("no linker command given, using default ar")
          callString = "ar rcs "
        else
          callString = config["linker"] + " "
        end
        return callString
      else
        Makr.log.warn("no config given, using bare linker ar")
        return "ar rcs "
      end
    end

    alias :getConfigString :makeLinkerCallString


    # libPath should be the complete path (absolute or relative) of the library with all standard fuss, like "libxy.a"
    def initialize(libFileName, build, configName)
      @libFileName = Makr.cleanPathName(libFileName)
      @libName = File.basename(@libFileName)
      super(StaticLibTask.makeName(@libFileName))
      @build = build
      @configName = configName

      # first we need a dependency on the target
      if not @build.hasTask?(@libFileName) then
        @targetDep = FileTask.new(@libFileName, false)
        @build.addTask(@libFileName, @targetDep)
      else
        @targetDep = @build.getTask(@libFileName)
      end
      addDependency(@targetDep)
      # now add another dependency task on the config
      @configTaskName = ConfigTask.makeName(@libFileName)
      if not @build.hasTask?(@configTaskName) then
        @configTask = ConfigTask.new(@configTaskName)
        @build.addTask(@configTaskName, @configTask)
      else
        @configTask = @build.getTask(@configTaskName)
      end
      addDependency(@configTask)

      Makr.log.debug("made StaticLibTask with @name=\"" + @name + "\"")
    end


    def update()
      # build compiler command and execute it
      linkCommand = makeLinkerCallString() + @libFileName
      @dependencies.each do |dep|
        # we only want dependencies that provide an object file
        if dep.instance_variable_defined?("@objectFileName") then
          linkCommand += " " + dep.objectFileName
        end
      end
      Makr.log.info("Building StaticLibTask \"" + @name + "\"\n\t" + linkCommand)
      successful = system(linkCommand)
      if not successful then
        Makr.log.fatal("linker error, exiting build process\n\n\n")
        Makr.abortBuild()
      end
      @targetDep.update() # we call this to update file information on the compiled target
      return true # we could check here for target change like proposed in CompileTask.update
    end


    def cleanupBeforeDeletion()
      system("rm -f " + @libFileName)
    end
  end




  


  def Makr.makeStaticLib(libFileName, build, taskCollection, libConfig = nil)
    Makr.cleanPathName(libFileName)
    libTaskName = StaticLibTask.makeName(libFileName)
    if not build.hasTask?(libTaskName) then
      build.addTask(libTaskName, StaticLibTask.new(libFileName, build, libConfig))
    end
    libTask = build.getTask(libTaskName)
    libTask.addDependencies(taskCollection)
    build.defaultTask = libTask # set this as default task in build
    return libTask
  end














  



  
  class ProgramTask < Task

    attr_reader    :programName  # identifies the binary to be build, wants full path as usual

    
    # make a unique name for ProgramTasks out of the programName which is to be compiled
    # expects a Pathname or a String
    def ProgramTask.makeName(programName)
       "ProgramTask__" + programName
    end


    def makeLinkerCallString() # g++ is always default value
      if @configName then
        Makr.log.debug("config name is: \"" + @configName + "\"")
        config = @build.getConfig(@configName)
        callString = String.new
        if (not config["linker"]) then
          Makr.log.warn("no linker command given, using default g++")
          callString = "g++ "
        else
          callString = config["linker"] + " "
        end
        # now add other flags and options
        if config["linker.lFlags"] then
          callString += config["linker.lFlags"] + " "
        end
        if config["linker.libPaths"] then
          callString += config["linker.libPaths"] + " "
        end
        if config["linker.libs"] then
          callString += config["linker.libs"] + " "
        end
        if config["linker.otherOptions"] then
          callString += config["linker.otherOptions"] + " "
        end
        return callString
      else
        Makr.log.warn("no config given, using bare linker g++")
        return "g++ "
      end
    end

    alias :getConfigString :makeLinkerCallString

    
    def initialize(programName, build, configName)
      @programName = Makr.cleanPathName(programName)
      super(ProgramTask.makeName(@programName))
      @build = build
      @configName = configName

      # first we make dependency on the target program file
      if not @build.hasTask?(@programName) then
        @compileTarget = FileTask.new(@programName, false)
        @build.addTask(@programName, @compileTarget)
      else
        @compileTarget = @build.getTask(@programName)
      end
      addDependency(@compileTarget)
      # now add another dependency task on the config
      @configTaskName = ConfigTask.makeName(@programName)
      if not @build.hasTask?(@configTaskName) then
        @configTask = ConfigTask.new(@configTaskName)
        @build.addTask(@configTaskName, @configTask)
      else
        @configTask = @build.getTask(@configTaskName)
      end
      addDependency(@configTask)

      Makr.log.debug("made ProgramTask with @name=\"" + @name + "\"")
    end
    

    def update()
      # build compiler command and execute it
      linkCommand = makeLinkerCallString() + " -o " + @programName
      @dependencies.each do |dep|
        # we only want dependencies that provide an object file
        if dep.instance_variable_defined?("@objectFileName") then
          linkCommand += " " + dep.objectFileName
        end
      end
      Makr.log.info("Building programTask \"" + @name + "\"\n\t" + linkCommand)
      successful = system(linkCommand)
      if not successful then
        Makr.log.fatal("linker error, exiting build process\n\n\n")
        Makr.abortBuild()
      end
      @compileTarget.update() # we call this to update file information on the compiled target
      return true # we could check here for target change like proposed in CompileTask.update
    end

    
    def cleanupBeforeDeletion()
      system("rm -f " + @programName)
    end
    
  end




  def Makr.makeProgram(progName, build, taskCollection, programConfig = nil)
    Makr.cleanPathName(progName)
    programTaskName = ProgramTask.makeName(progName)
    if not build.hasTask?(programTaskName) then
      build.addTask(programTaskName, ProgramTask.new(progName, build, programConfig))
    end
    progTask = build.getTask(programTaskName)
    progTask.addDependencies(taskCollection)
    build.defaultTask = progTask # set this as default task in build
    return progTask
  end









  
  


  class Build

    attr_reader   :buildPath, :configs, :postUpdates
    attr_accessor :defaultTask, :nrOfThreads


    # build path should be absolute and is read-only once set in this "ctor"
    def initialize(buildPath) 
      @buildPath = Makr.cleanPathName(buildPath)
      @buildPath.freeze

      @postUpdates = Array.new

      # task hash
      @taskHash      = Hash.new            # maps task names to tasks (names are for example full path file names)
      @taskHashCache = Hash.new            # a cache for the task hash that is loaded below

      # configs
      @configs = Hash.new
      @configsFileName = @buildPath + "/.makr/config.txt"
      @configsFileName.freeze

      @defaultTask = nil
      @nrOfThreads = nil
    end


    def build(taskName = nil)
      updateTraverser = UpdateTraverser.new(@nrOfThreads)
      if taskName.kind_of? String then
        raise("unknown taskName: " + taskName) if not hasTask?(taskName)
        updateTraverser.traverse(getTask(taskName))
        return
      else
        # check default task or search for a single task without dependant tasks (but give warning)
        if @defaultTask.kind_of? Task then
          updateTraverser.traverse(@defaultTask)
        else
          Makr.log.warn("no (default) task given for build, searching for root task")
          taskFound = Array.new
          @taskHash.each_value do |value|
            taskFound.push(value) if value.dependantTasks.empty?
          end
          if taskFount.size == 1 then
            updateTraverser.traverse(taskFound.first)
          else
            raise "failed with all fallbacks in Build.build"
          end
        end
      end
    end
    

    def registerPostUpdate(task)
      @postUpdates.push(task)
    end

    
    def doPostUpdates()
      @postUpdates.each do |task|
        task.postUpdate()
      end
      @postUpdates.clear() # afterwards, we clear the array
    end
    

    def hasTask?(taskName)
      return (@taskHash.has_key?(taskName) or @taskHashCache.has_key?(taskName))
    end


    def getTask(taskName)
      if @taskHash.has_key?(taskName) then
        return @taskHash[taskName]
      elsif @taskHashCache.has_key?(taskName) then
        addTaskPrivate(taskName, @taskHashCache[taskName])  # we make a copy upon request
        return @taskHash[taskName]
      else
        raise "[makr] Task not found! " + taskName
      end
    end


    def addTask(taskName, task)
        addTaskPrivate(taskName, task)
    end

    
    def removeTask(taskName)
      if @taskHash.has_key?(taskName) then # we dont bother about cache here, as cache is overwritten on save to disk
        @taskHash.delete(taskName)
      else
        raise "[makr] removal of non-existant task requested!"
      end
    end


    def hasConfig?(name)
      return @configs.has_key?(name)
    end

    
    def getConfig(name)
      if not hasConfig?(name) then
        raise "[makr] no such config: " + name
      end
      @configs[name]
    end


    def makeNewConfig(name, parentName = nil)
      if hasConfig?(name) then
        return getConfig(name)
      end
      parent = nil
      if parentName then
        if not hasConfig?(parentName) then
          raise "[makr] requested config parent with name " + parentName + " not existing!"
        end
        parent = @configs[parentName]
      end
      @configs[name] = Config.new(name, parent)
    end


    def makeNewConfigForTask(name, task)
      if task.configName == name then # already have this config
        return getConfig(name)
      end
      newConf = makeNewConfig(name, task.configName)
      task.configName = name
      return newConf
    end


    # dump helper functions

    
    def loadConfigs()  # loads configs from build dir
      if File.file?(@configsFileName) then
        Makr.log.info("found config file, now restoring")
        lines = IO.readlines(@configsFileName)
        lineIndex = 0
        while lineIndex < lines.size() do
          if (not (lines[lineIndex])) or (lines[lineIndex] == "") then
            lineIndex += 1
            next
          end
          config = Config.new("")
          parsingGood, lineIndex, parentName = config.input(lines, lineIndex)
          if parsingGood then
            lineIndex += 1 # go on to next line
            # check name for existence first (this is not an error)
            if @configs.has_key?(config.name) then
              Makr.log.error("already having config parsed before line " + lineIndex.to_s)
              next
            end
            if parentName then
              if not @configs.has_key?(parentName) then
                Makr.log.error("parent name unknown in config file before lineIndex: " + lineIndex.to_s)
                return
              end
              config.setParent(@configs[parentName])
            end
            if config.name != "" then  # we only add configs with a name!
              @configs[config.name] = config
            end
          else
            Makr.log.error("parse error in config file before lineIndex: " + lineIndex.to_s)
            return
          end
        end
      else
        Makr.log.info("could not find or open config file.")
      end
    end


    def dumpConfigs(cleanupConfigs)
      if cleanupConfigs then
        cleanConfigs()
      end
      File.open(@configsFileName, "w") do |dumpFile|
        @configs.each do |key, value|
          value.output(dumpFile)
        end
      end
    end


    def cleanTaskHashCache()
      # remove tasks that want to be deleted and their
      deleteArr = Array.new
      @taskHashCache.each do |key, value|
        if value.mustBeDeleted? then
          deleteArr.push(value)
        end
      end
      Makr.log.debug("cleanTaskHashCache(), number of tasks to be cleansed: " + deleteArr.size.to_s)
      while not deleteArr.empty? do
        task = deleteArr.delete_at(0)
        @taskHashCache.delete(task.name)
        deleteArr.concat(task.dependantTasks)
        task.cleanupBeforeDeletion()
      end
    end
  

    def prepareDump()
      @taskHashCache.replace(@taskHash)
      @taskHash.clear()
    end


    def unprepareDump()
      @taskHash.replace(@taskHashCache)
      @taskHashCache.clear()
    end


  protected

  
    def addTaskPrivate(taskName, task)
      if @taskHash.has_key? taskName then
        Makr.log.warn("Build::addTaskPrivate, taskName exists already!: " + taskName)
        return
      end
      @taskHash[taskName] = task   # we dont bother about cache here, as cache is overwritten on save to disk
      # if a task is added all its dependencies are also added automatically, if it has em'
      addArr = task.dependencies.clone
      while not addArr.empty? do
        curTask = addArr.delete_at(0)
        if not @taskHash.has_key? curTask.name then
          @taskHash[curTask.name] = curTask
        end
        addArr.concat(curTask.dependencies.clone)
      end
    end

    
    def cleanConfigs()
      saveHash = Hash.new
      @taskHash.each do |key, value|
        if value.configName and not (saveHash.has_key?(value.configName)) then # save each config once
          saveHash[value.configName] = @configs[value.configName]
          @configs.delete(value.configName)
        end
      end
      # now only Config instance remain in @configs, that have no reference in tasks.
      # we could delete them all, but some are intermediate nodes in the Config graph
      # thus we only delete those, that have no childs recursively
      deletedSomething = true
      while deletedSomething
        deletedSomething = false
        @configs.delete_if do |name, config|
          if config.childs.empty? then
            config.unparent()
            deletedSomething = true
          else
            false
          end
        end
      end
      saveHash.each do |key, value|
        @configs[key] = value
      end
    end

  end



  def Makr.loadBuild(buildPath)
    buildPath = Makr.cleanPathName(buildPath)
    buildPathMakrDir = buildPath + "/.makr"
    # if build dir and subdirs does not exist, create it
    raise "[makr] given build dir is not a dir!" if (not File.directory?(buildPath)) and File.exist?(buildPath)
    Dir.mkdir(buildPath) if not File.directory?(buildPath)
    raise "[makr] \"" + buildPath + "/.makr\" is not a dir!" \
      if (not File.directory?(buildPathMakrDir)) and File.exist?(buildPathMakrDir)
    Dir.mkdir(buildPathMakrDir) if not File.directory?(buildPathMakrDir)

    buildPathBuildDumpFileName = buildPathMakrDir + "/build.ruby_marshal_dump"

    if not File.file?(buildPathBuildDumpFileName) then
      Makr.log.warn("could not find or open build dump file, build will be setup new!")
      return Build.new(buildPath) 
    end
    Makr.log.info("found build dump file, now restoring")
    File.open(buildPathBuildDumpFileName, "rb") do |dumpFile|
      build = Marshal.load(dumpFile)
      build.loadConfigs()
      build.cleanTaskHashCache()
      return build
    end
  end

  

  def Makr.saveBuild(build, cleanupConfigs = true)
    build.dumpConfigs(cleanupConfigs)
    build.prepareDump()
    saveFileName = build.buildPath + "/.makr/build.ruby_marshal_dump"
    File.open(saveFileName, "wb") do |dumpFile|
      Marshal.dump(build, dumpFile)
    end
    build.unprepareDump()
  end



  

  class UpdateTraverser

    @@abortUpdate = false
    def UpdateTraverser.abortUpdate
      @@abortUpdate
    end
    def UpdateTraverser.abortUpdate=(arg)
      @@abortUpdate = arg
    end

    
    class Updater
      
      def initialize(task, threadPool)
        @task = task
        @threadPool = threadPool
      end
      
      # we need to go up the tree with the traversal even in case dependency did not update
      # just to increase the dependenciesUpdatedCount in each marked node so that in case
      # of the update of a single child, the node will surely be updated! An intermediate node
      # might not be updated, as the argument callUpdate is false, but the algorithm logic
      # still needs to handle dependant tasks for the above reason.
      def run(callUpdate)
        return if UpdateTraverser.abortUpdate # cooperatively abort build

        @task.mutex.synchronize do
          if not @task.updateMark then
            raise "[makr] Unexpectedly starting on a task that needs no update!"
          end
          retVal = false
          if callUpdate then
            retVal = @task.update()
          end
          return if UpdateTraverser.abortUpdate # cooperatively abort build
          @task.updateMark = false
          @task.dependantTasks.each do |dependantTask|
            dependantTask.mutex.synchronize do
              if dependantTask.updateMark then # only work on dependant tasks that want to be updated eventually
                dependantTask.dependencyWasUpdated ||= retVal
                # if we are the last thread to reach the dependant task, we will run the next thread
                # on it. The dependant task needs to be updated if at least a single dependency task
                # was update (which may not be the task of this thread)
                dependantTask.dependenciesUpdatedCount = dependantTask.dependenciesUpdatedCount + 1
                if (dependantTask.dependenciesUpdatedCount == dependantTask.dependencies.size) then
                  updater = Updater.new(dependantTask, @threadPool)
                  @threadPool.execute {updater.run(dependantTask.dependencyWasUpdated)}
                end
              end
            end
          end
        end  
      end
      
    end # end of nested class Updater

    
    def initialize(nrOfThreadsInPool = nil)
      @threadPool = ThreadPool.new(nrOfThreadsInPool)
    end
    

    # root must be a task. The traversal works as follows: we walk down the DAG until we reach
    # tasks with no dependencies. Upon this walk we mark all tasks we visit. Then, from the
    # independent tasks, we walk up again and run an Updater thread on each marked node. The number
    # of threads is limited by a thread pool.
    #
    # TODO: We expect the DAG to have no cycles here. Should we check?
    def traverse(root) 
      collectedTasksWithNoDeps = Array.new
      recursiveMarkAndCollectTasksWithNoDeps(root, collectedTasksWithNoDeps)
      collectedTasksWithNoDeps.uniq!
      Makr.log.debug("collectedTasksWithNoDeps.size: " + collectedTasksWithNoDeps.size.to_s)
      collectedTasksWithNoDeps.each do |noDepsTask|
        updater = Updater.new(noDepsTask, @threadPool)
        @threadPool.execute {updater.run(true)}
      end
      @threadPool.join()
    end

    
    def recursiveMarkAndCollectTasksWithNoDeps(task, collectedTasksWithNoDeps)
      # prepare the task variables upon descend
      task.updateMark = true
      task.dependenciesUpdatedCount = 0
      task.dependencyWasUpdated = false

      # then collect, if no further deps or recurse
      if task.dependencies.empty? then
        collectedTasksWithNoDeps.push(task)
        return
      end
      task.dependencies.each{|dep| recursiveMarkAndCollectTasksWithNoDeps(dep, collectedTasksWithNoDeps)}
    end
    
  end













  # build construction helper classes


  class FileCollector

    # dirName is expected to be a path name
    def FileCollector.collect(dirName, pattern = "*", recurse = true)
      fileCollection = Array.new
      privateCollect(dirName, pattern, nil, fileCollection, recurse)  # exclusion pattern is empty
      return fileCollection
    end

    # convenience methods
    def FileCollector.collectRecursive(dirName, pattern = "*")
      return FileCollector.collect(dirName, pattern, true)
    end
    def FileCollector.collectFlat(dirName, pattern = "*")
      return FileCollector.collect(dirName, pattern, false)
    end

    def FileCollector.collectExclude(dirName, pattern, exclusionPattern, recurse = true)
      fileCollection = Array.new
      privateCollect(dirName, pattern, exclusionPattern, fileCollection, recurse)
      return fileCollection
    end

    protected
  
    def FileCollector.privateCollect(dirName, pattern, exclusionPattern, fileCollection, recurse)
      Makr.cleanPathName(dirName)
      # first recurse into sub directories
      if recurse then
        Dir[dirName + "/*/"].each do |subDir|
          privateCollect(subDir, pattern, exclusionPattern, fileCollection, recurse)
        end
      end
      if exclusionPattern and not exclusionPattern.empty? then
        files = Dir[ dirName + "/" + pattern ]
        exclusionFiles = Dir[ dirName + "/" + exclusionPattern ]
        files.each do |fileName|
          fileCollection.push(fileName) if (File.file?(fileName) and not exclusionFiles.include?(fileName))
        end
      else
        fileCollection.concat(Dir[ dirName + "/" + pattern ])
      end
    end
  end





  

  class CompileTaskGenerator

    def initialize(build, configName = nil)
      @build = build
      @configName = configName
    end

    
    def generate(fileName)
      Makr.cleanPathName(fileName)
      compileTaskName = CompileTask.makeName(fileName)
      if not @build.hasTask?(compileTaskName) then
        localTask = CompileTask.new(fileName, @build, @configName)
        @build.addTask(compileTaskName, localTask)
      end
      tasks = Array.new
      tasks.push(@build.getTask(compileTaskName))
      return tasks
    end
    
  end




  class MocTaskGenerator

    def initialize(build, compileTaskConfigName = nil, mocTaskConfigName = nil)
      @build = build
      @mocTaskConfigName = mocTaskConfigName
      @compileTaskConfigName = compileTaskConfigName
    end


    def generate(fileName)
      # first check, if file has Q_OBJECT, otherwise we return no tasks
      return nil if not MocTask.containsQ_OBJECTMacro?(fileName)

      # Q_OBJECT contained, now go on
      Makr.cleanPathName(fileName)
      mocTaskName = MocTask.makeName(fileName)
      if not @build.hasTask?(mocTaskName) then
        mocTask = MocTask.new(fileName, @build, @mocTaskConfigName)
        @build.addTask(mocTaskName, mocTask)
      end
      mocTask = @build.getTask(mocTaskName)
      tasks = Array.new
      tasks.push(mocTask)
      compileTaskName = CompileTask.makeName(mocTask.mocFileName)
      if not @build.hasTask?(compileTaskName) then
        compileTask = CompileTask.new(mocTask.mocFileName, @build, @compileTaskConfigName, true, mocTask)
        @build.addTask(compileTaskName, compileTask)
      end
      compileTask = @build.getTask(compileTaskName)
      tasks.push(compileTask)
      return tasks
    end

  end







  
  # can be called with an array of file names or a single file name
  def Makr.applyGenerators(fileCollection, generatorArray)
    # first check, if we only have a single file
    fileCollection = [Makr.cleanPathName(fileCollection)] if fileCollection.kind_of? String
    tasks = Array.new
    fileCollection.each do |fileName|
      generatorArray.each do |gen|
        return tasks if UpdateTraverser.abortUpdate # cooperatively abort build
        genTasks = gen.generate(fileName)
        tasks.concat(genTasks) if genTasks
      end
    end
    return tasks
  end










  




  




  

  # script argument management

  class ScriptArguments

    attr_reader :scriptFile, :arguments

    def initialize(scriptFile, arguments)
      @scriptFile = scriptFile
      @arguments = arguments
    end
  end

  
  class ScriptArgumentsStorage
    @@store = Array.new
    def ScriptArgumentsStorage.get()
      @@store
    end
  end
  

  def Makr.pushArgs(scriptArguments)
    ScriptArgumentsStorage.get.push(scriptArguments)
  end

  
  def Makr.popArgs()
    if (ScriptArgumentsStorage.get.size < 2) then
      Makr.log.fatal "Tried to remove the minimum arguments from stack, exiting!"
      Makr.abortBuild()
    end
    ScriptArgumentsStorage.get.pop
  end

  
  def Makr.getArgs()
    ScriptArgumentsStorage.get.last
  end








  
  # loads a Makrfile.rb from the given dir and executes it using Kernel.load and push/pops the current ScriptArguments, so that they are save
  def Makr.makeDir(dir)
    Makr.cleanPathName(dir)
    makrFilePath = dir + "/Makrfile.rb"
    if File.exist?(makrFilePath) then
      Makr.pushArgs(Makr::ScriptArguments.new(makrFilePath, getArgs().arguments.clone))
      Kernel.load(makrFilePath)
      popArgs()
    else
      Makr.log.error("Subdir build call with " + makrFilePath + ", file not found!")
      Makr.abortBuild()
    end
  end







  
end     # end of module makr ######################################################################################








####################################################################################################################

# MAIN logic and interface with client code following

####################################################################################################################

# first start logger and set level
Makr.log.level = Logger::DEBUG
Makr.log.formatter = proc { |severity, datetime, progname, msg|
    "[makr #{severity} #{datetime}]    #{msg}\n"
}
Makr.log << "\n\nmakr version 2011.09.11\n\n"  # just give short version notice on every startup (Date-encoded)

# then set the signal handler to allow cooperative aborting of the build process on SIGUSR1
Signal.trap("USR1")  do
  puts Makr.log.fatal("Aborting build on signal USR1")
  Makr.abortBuild()
end

# we need a basic ScriptArguments object pushed to stack (kind of dummy holding ARGV)
# we use a relative path here to allow moving of build dir
Makr.pushArgs(Makr::ScriptArguments.new("./Makrfile.rb", ARGV))
# then we reuse the makeDir functionality building the current directory
Makr.makeDir(".")
