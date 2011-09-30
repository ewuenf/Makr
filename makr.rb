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
    attr_reader :nrOfThreads

    # Initialize with nrOfThreads threads to run (if count is not given, all processors of the system will be used)
    def initialize(nrOfThreads = nil, queue_limit = 0)
      @mutex = Mutex.new
      @executors = []
      @queue = []
      @queue_limit = queue_limit
      if nrOfThreads then
        @nrOfThreads = nrOfThreads
      else
        @nrOfThreads = `grep -c processor /proc/cpuinfo`.to_i  # works only on linux (and maybe most unixes)
      end
      @nrOfThreads.times { @executors << Executor.new(@queue, @mutex) }
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
      @nrOfThreads
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
  def Makr.log()
    @log ||= Logger.new(STDOUT)
  end




  # central aborting method (cooperative abort, see UpdateTraverser::Updater)
  def Makr.abortBuild()
    Makr.log.fatal("Aborting build process.")
    UpdateTraverser.abortBuild = true
  end




  # a helper function to clean a pathName fed into the function coming out with no slashes at the end
  def Makr.cleanPathName(pathName)
    Makr.log.warn("Trying to clean empty pathName!") if (not pathName or pathName.empty?)
    # first remove slashes at the end
    pathName.gsub!(/\/+$/, '') # returns nil, if no substitution is performed
    # then, if we have a relative path, let it begin with ./
    if pathName.index("/") != 0 then # have a relative path
      pathName = "./" + pathName if pathName.index("./") != 0
    end
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


    # constructs and return a new Config with this config as parent
    def makeChild(newName)
      Config.new(newName, self)
    end
    alias :derive :makeChild


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


    # copies all keys of the immediate parent to this config or only the key given
    def copyParent(key = nil)
      return if not @parent
      if key then
        @hash[key] ||= @parent[key]
      else
        # collect the complete hash
        # duplicate keyz are resolved in favor of the argument of the merge!-call, which is what we want here
        # (this way we overwrite with the parents keys)
        @hash.merge!(@parent.hash)
      end
    end


    # adds value to the keys value if it is not already included (useful for adding compiler options etc)
    def addUnique(key, value)
      curVal = @hash[key]
      if curVal then
        curVal += value if not curVal.include?(value)
        @hash[key] = curVal
      else
        @hash[key] = value
      end
    end


    # convenience mix function of copyParent and addUnique
    def copyAddUnique(key, value)
      copyParent(key)
      addUnique(key, value)
    end


    # accessor function, like hash, see examples. Local key overrides parent key.
    def [](key)
      # there are some cases to consider:
      #    * we have the key and return it or
      #    * we have do not have the key
      #      * we have no parent and return nil
      #      * we have a parent and recursively check for the key
      @hash[key] or (@parent ? @parent[key] : nil)
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


  protected # comparable to private in C++

    def addChild(config)
      @childs.push(config)
    end


    def removeChild(config)
      @childs.delete(config)
    end


  end






  # Basic class and concept representing a node in the dependency DAG and any type of action that
  # needs to be performed (such as compilation of a source file). Each task can have a configuration
  # attached (see class Config)
  class Task

    # dependencies are of course tasks this task depends on. Additionally we have the array of
    # dependantTask that depend on this task (double-linked graph structure)
    attr_reader :name, :dependencies, :dependantTasks
    # targets is an Array of file names containing the targets produced by the task (may be empty if no files are produced)
    # this can be used to resolve dependencies on generated files
    attr_reader :targets
    # reference to Config object
    attr_accessor :config
    # these are used by the multi-threaded UpdateTraverser (most of these are related to update() and postUpdate(),
    # updateError is related to handleUpdateError() )
    attr_accessor :mutex, :updateMark, :dependenciesUpdatedCount, :updateDuration, :updateError
    # state determines for inner nodes of the task graph, if an update is necessary:
    # for leaf nodes the state must be set by the nodes upon call to the update() function, while
    # for inner nodes, the state is set by UpdateTraverser::Updater to match an accumulation
    # of the child states, so that upon a new build run, a necessary update can be detected
    attr_accessor :state


    # name must be unique within a build (see class Build)!
    def initialize(name, config = nil)
      @name = name
      @dependencies = Array.new
      @dependantTasks = Array.new

      @config = config

      # regarding the meaning of these see class UpdateTraverser
      @mutex = Mutex.new
      @updateMark = false
      @dependenciesUpdatedCount = 0
      @updateDuration = 1.0
      @updateError = false

      @state = @accumulatedChildState = String.new
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


    # Every subclass should provide an "update()" function, that returns wether the update was successful or not
    # The task graph itself should be unchanged during update. Use function postUpdate() for this purpose.
    def update()
      return true # default is always successful update
    end


    # The method postUpdate() is optionally called after all tasks have been "update()"d. Tasks need to register for the
    # postUpdate()-call during the update()-call using "Build::registerPostUpdate(self)". While update() is called in
    # parallel on the task graph and should not modify the graph, this function is called on all registered tasks in a
    # single thread, so that no issues with multi-threading can occur. As this obviously is a bottleneck, the function
    # should only be used if it is absolutely necessary to modify the task structure upon updating procedure.
    # This behaviour might change in future revisions of this tool, as the author or someone else might get better
    # concepts out of his brain.
    def postUpdate()
    end


    # called once before build starts on all tasks of the build
    def preUpdate()
    end


    # this is called if upon update of a dependency (or a dependency of a dependency...) an error occurred
    def handleUpdateError()
      deleteTargets()
    end


    def deleteTargets()
      return if not @targets
      @targets.each do |target|
        File.delete target if File.exists? target
      end
    end

    alias :deleteTargetsBeforeUpdate :deleteTargets # see UpdateTraverser::Updater::run()


    # can be impletemented by subclasses indicating that this task is no longer valid due to for example a missing file
    def mustBeDeleted?()
      false
    end


    # kind of debugging to_s function
    def printDependencies(prefix = "")
      Makr.log.info(prefix + @name + " deps size: " + @dependencies.size.to_s)
      @dependencies.each do |dep|
        dep.printDependencies(prefix + "  ")
      end
    end


    def cleanupBeforeDeletion()  # interface mainly for tasks generating targets (removing these)
      deleteTargets()
    end

  end






  # --
  # RDoc stops processing comments if it finds a comment line containing '#--'
  # Commenting can be turned back on with a line that starts '#++'.
  #
  # now some basic Task derived classes follow
  #
  # ++





  # This class represents the dependency on changed strings in a Config, it is used for example in CompileTask
  class ConfigTask < Task

    # make a unique name for CompileTasks out of the fileName which is to be compiled
    def ConfigTask.makeName(name)
      "ConfigTask__" + name
    end


    def initialize(name)
      super
    end


    def update()
      # produce a nice message in error case (we want exactly one dependant task)
      raise "[makr] ConfigTask #{name} does not have a dependant task, but needs one!" if (not (dependantTasks.size == 1))
      # just update state with config string from the only dependantTask
      @state = dependantTasks.first.getConfigString()
      return true # task is always successful
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
    attr_accessor :useFileHash # for setting hash usage individually, overrides class variable


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
      # first check missing file case
      if (not File.file?(@fileName)) then
        @state = String.new  # empty string means update is definitely necessary
        if @missingFileIsError then
          Makr.log.fatal("file #{@fileName} is unexpectedly missing!\n\n")
          return false # error case
        end
        Makr.log.debug("file #{@fileName} is missing, induces update.")
        return true # success case
      end

      # now we either use the hash of the file or we use file attributes to determine changes
      unless @useFileHash.is_a? NilClass then # the local variable overrides class variable if set
        useFileHash = @useFileHash
      else
        useFileHash = @@useFileHash
      end

      hasChanged = false # used only for output below

      if useFileHash then                     # file hash
        curHash = MD5.new(open(@fileName, 'rb').read).hexdigest
        if(@fileHash != curHash)
          @fileHash = curHash
          @state = @fileHash  # compose state from file state
          hasChanged = true
        end

      else                                    # file attribs checking
        stat = File.stat(@fileName);
        if (@time != stat.mtime) or (@size != stat.size) then
          @time = stat.mtime
          @size = stat.size
          @state = @time.to_s + @size.to_s # compose state from file state
          hasChanged = true
        end
      end

      if hasChanged then
        Makr.log.debug("file #{@fileName} has changed, induces update.")
      end

      return true # always successful, when here
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
      # substitution of '_' with '__' prevents collisions
      @build.buildPath + "/" + fileName.gsub('_', '__').gsub('/', '_').gsub('.', '_') + ".o" 
    end


    # the path of the input and output file of the compilation
    attr_reader :fileName, :objectFileName
    attr_accessor :checkOnlyUserHeaders


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
        @compileTargetDep = FileTask.new(@objectFileName, false)
        @build.addTask(@objectFileName, @compileTargetDep)
      else
        @compileTargetDep = @build.getTask(@objectFileName)
      end
      @targets = [@objectFileName] # set targets produced by this task
      deleteTargets() # delete targets upon construction to guarantee a first update

      # construct a dependency task on the configuration
      @configTaskDepName = ConfigTask.makeName(@name)
      if not @build.hasTask?(@configTaskDepName) then
        @configTaskDep = ConfigTask.new(@configTaskDepName)
        @build.addTask(@configTaskDepName, @configTaskDep)
      else
        @configTaskDep = @build.getTask(@configTaskDepName)
      end

      # Dependencies are setup once upon first call in preUpdate and then after each build in postUpdate.
      # This is used to get generated source files (including headers) from other tasks that have been
      # setup before and add dependencies to these.
      @calledPreUpdate = false # done only once, thus a boolean flag

      Makr.log.debug("made CompileTask with @name=\"" + @name + "\"") # debug feedback
    end


    def preUpdate()
      return if @calledPreUpdate
      @calledPreUpdate = true
      getDepsStringArrayFromCompiler()
      buildDependencies() # also adds dependencies generated in initialize
    end


    # calls compiler with complete configuration options to automatically generate a list of dependency files
    # the list is parsed in buildDependencies()
    # Parsing is seperated from dependency generation because during the update step we also check
    # dependencies but do no rebuild them as the tree should not be changed during multi-threaded update
    # function return true, if successful, false otherwise
    def getDepsStringArrayFromCompiler()
      # always clear input lines upon call
      @dependencyLines = Array.new

      # then check, if we need to to
      if (@fileIsGenerated and (not File.file?(@fileName))) then
        Makr.log.error("generated file is missing: #{@fileName}")
        return false
      end

      # now we check, if we also want system header deps
      # the local variable overrides class variable if set
      checkOnlyUserHeaders = (@checkOnlyUserHeaders)? @checkOnlyUserHeaders : @@checkOnlyUserHeaders
      # system headers are excluded using compiler option "-MM", else "-M"
      depCommand = makeCompilerCallString() + ((checkOnlyUserHeaders)?" -MM ":" -M ") + @fileName

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
        Makr.cleanPathName(depFile)
        next if (depFile == @fileName) # go on if dependency on source file encountered
        if @build.hasTask?(depFile) then
          task = @build.getTask(depFile)
          if not @dependencies.include?(task)
            addDependency(task)
          end
        elsif (generatorTask = @build.getTaskForTarget(depFile)) then
          if not @dependencies.include?(generatorTask)
            addDependency(generatorTask)
          end
        else
          task = FileTask.new(depFile)
          @build.addTask(depFile, task)
          addDependency(task)
        end
      end

    end


    def update()
      # here we execute the compiler to deliver an update on the dependent includes before compilation. We could do this
      # in postUpdate, too, but we assume this to be faster, as the files should be in OS cache afterwards and
      # thus the compilation (which is the next step) should be faster
      return false if not getDepsStringArrayFromCompiler()

      # we do not modify task structure on update and defer this to the postUpdate call like good little children
      @build.registerPostUpdate(self)

      # construct compiler command and execute it
      compileCommand = makeCompilerCallString() + " -c " + @fileName + " -o " + @objectFileName
      Makr.log.info("CompileTask #{@name}: Executing compiler\n\t" + compileCommand)
      successful = system(compileCommand)
      Makr.log.error("Error in CompileTask #{@name}") if not successful
      @compileTargetDep.update() # update file information on the compiled target in any case
      return successful
    end


    def postUpdate()
      buildDependencies()  # assuming we have called the compiler already in update giving us the deps strings
    end

  end









  # TODO: there are some comonalities in the following classes, use mixins?
  #       (replacing "ProgramTask.makeName" with "self.class.makeName" for example)




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
      if not @build.hasTask?(@libFileName) then
        @libTargetDep = FileTask.new(@libFileName, false)
        @build.addTask(@libFileName, @libTargetDep)
      else
        @libTargetDep = @build.getTask(@libFileName)
      end
      addDependency(@libTargetDep)
      @targets = [@libFileName]

      # now add another dependency task on the config
      @configDepName = ConfigTask.makeName(@libFileName)
      if not @build.hasTask?(@configDepName) then
        @configDep = ConfigTask.new(@configDepName)
        @build.addTask(@configDepName, @configDep)
      else
        @configDep = @build.getTask(@configDepName)
      end
      addDependency(@configDep)

      Makr.log.debug("made DynamicLibTask with @name=\"" + @name + "\"")
    end


    def update()
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
      return successful
    end

  end





  # constructs a dynamic lib target with the given taskCollection as dependencies, takes an optional libConfig
  # for configuration options. Sets default task in build!
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
      if not @build.hasTask?(@libFileName) then
        @libTargetDep = FileTask.new(@libFileName, false)
        @build.addTask(@libFileName, @libTargetDep)
      else
        @libTargetDep = @build.getTask(@libFileName)
      end
      addDependency(@libTargetDep)
      @targets = [@libFileName]

      # now add another dependency task on the config
      @configDepName = ConfigTask.makeName(@libFileName)
      if not @build.hasTask?(@configDepName) then
        @configDep = ConfigTask.new(@configDepName)
        @build.addTask(@configDepName, @configDep)
      else
        @configDep = @build.getTask(@configDepName)
      end
      addDependency(@configDep)

      Makr.log.debug("made StaticLibTask with @name=\"" + @name + "\"")
    end


    def update()
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
      return successful
    end

  end






  # constructs a static lib target with the given taskCollection as dependencies, takes an optional libConfig
  # for configuration options. Sets default task in build!
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
      if not @build.hasTask?(@programName) then
        @targetDep = FileTask.new(@programName, false)
        @build.addTask(@programName, @targetDep)
      else
        @targetDep = @build.getTask(@programName)
      end
      addDependency(@targetDep)
      @targets = [@programName]

      # now add another dependency task on the config
      @configDepName = ConfigTask.makeName(@programName)
      if not @build.hasTask?(@configDepName) then
        @configDep = ConfigTask.new(@configDepName)
        @build.addTask(@configDepName, @configDep)
      else
        @configDep = @build.getTask(@configDepName)
      end
      addDependency(@configDep)

      Makr.log.debug("made ProgramTask with @name=\"" + @name + "\"")
    end


    def update()
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
      return successful
    end

  end



  # constructs a ProgramTask with the given taskCollection as dependencies, takes an optional programConfig
  # for configuration options. Sets default task in build!
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












  # One of the central classes in Makr. Represents a variant build (in a given buildPath). Instances of Build
  # are stored using Makr.saveBuild and restored via Makr.loadBuild, which should be one of the first commands
  # in a Makrfile.rb. Without this cache, everything would be rebuild (no checking for existing targets etc.).
  # Additionally, this class provides automatic cleanup and pruning of the configs and tasks in the cache.
  # As Makr.saveBuild and Makr.loadBuild use the Marshall functionality of ruby, everything that is referenced
  # from the instance is saved and restored (which typically comprises almost all objects created in a Makrfile.rb).
  # To ensure that Makr.saveBuild is called, use a block with saveAfterBlock in the Makrfile.rb (just have a look
  # at the examples).
  class Build

    attr_reader   :buildPath, :configs, :postUpdates
    attr_accessor :defaultTask, :nrOfThreads
    # hash from a file name to an Array of Task s (this is a kind of convenience member, see buildTasksForFile). It can
    # be used to realize the build of a single file provided by many IDEs)
    attr_accessor :fileHash
    # set this to true, if build should stop on first detected error (default behaviour)
    attr_accessor :stopOnFirstError
    # this is set to true if an error occured during the last build
    attr_reader :buildError


    # build path identifies the build directory where the cache of configs and tasks is stored in a
    # subdirectory ".makr" and loaded upon construction, if the cache exists (which is fundamental to the
    # main build functionality "rebuild only tasks, that need it").
    def initialize(buildPath) 
      @buildPath = Makr.cleanPathName(buildPath)
      @buildPath.freeze # make sure this isnt changed during execution

      @postUpdates = Array.new

      # hash from taskName to task (the cache is central to the update-on-demand-functionality and for automatic cleanup
      @taskHash      = Hash.new            # maps task names to tasks (names are for example full path file names)
      @taskHashCache = Hash.new            # a cache for the task hash that is loaded below
      @fileHash = Hash.new                 # convenience member, see above

      @stopOnFirstError = true
      @buildError = false

      @configs = Hash.new

      @defaultTask = nil
      @nrOfThreads = nil
    end


    # block concept to ensure automatic save after block is done (should embrace all actions in a Makrfile.rb)
    def saveAfterBlock(cleanupConfigs = true)
      yield
    ensure
      Makr.saveBuild(self, cleanupConfigs)
    end


    # central function for building a given task. If task is not given, the defaultTask is used
    # or if even that one is not set, a root tasks with no dependant tasks is searched and
    # constructed. If even that fails, an exception is thrown.
    # The variable nrOfThreads influences, how many threads perform the update. If
    # no number is given, the number of available processors is used (see ThreadPool).
    def build(task = nil)
      @buildError = false
      updateTraverser = UpdateTraverser.new(@nrOfThreads)
      effectiveTask = nil
      if task then
        effectiveTask = task
      else
        # check default task or search for a single task without dependant tasks (but give warning)
        if @defaultTask.kind_of? Task then
          effectiveTask = @defaultTask
        else
          Makr.log.warn("no (default) task given for build, searching for root task")
          tasksFound = @taskHash.values.select {|v| v.dependantTasks.empty?}
          if tasksFound.size >= 1 then
            if tasksFound.size > 1 then
              Makr.log.warn("more than one root task found, taking the first found, which is: " + tasksFound.first.name)
            end
            effectiveTask = tasksFound.first
          else
            raise "failed with all fallbacks in Build.build"
          end
        end
      end

      # call preUpdate on all tasks before starting UpdateTraverser
      # we need to take care, that the taskHash might get modified during iteration, so Hash.values
      # returns a *new* array with all tasks at call time, on which we can safely iterate
      Makr.log.info( " \n\n ############################# doing preUpdate() \n\n\n" )
      @taskHash.values.each {|task| task.preUpdate() }

      Makr.log.info( " \n\n ############################# doing update() \n\n\n" )
      updateTraverser.traverse(self, effectiveTask)
      @buildError = effectiveTask.updateError

      Makr.log.info( " \n\n ############################# doing postUpdate() \n\n\n" )
      doPostUpdates() if not @buildError

      # finally give message:
      if not UpdateTraverser.abortBuild and not @buildError then
        Makr.log.info("\n")
        Makr.log.info("\n")
        Makr.log.info("############ ;-) successfully build task ############")
      else
        Makr.log.info("\n")
        Makr.log.info("\n")
        Makr.log.info("~~~~~~~~~~~~ :(  ERROR on building task  ~~~~~~~~~~~~")
      end
    end


    # this function is called with the name of a source file and builds all associated tasks and their dependencies
    # (which typically amounts to the compilation of a single file)
    def buildTasksForFile(fileName)
      if not @fileHash[fileName]
        raise "fileName not found in buildTasksForFile(fileName), maybe you added tasks without using Generators or" \
              " the ones you used are not compliant"
      end
      @fileHash[fileName].each do |task|
        build(task)
      end
    end


    def resetUpdateMarks()
      @taskHash.each_value do |value|
        value.updateMark = false
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


    # this is not the same as fileHash, as it looks at the targets of all tasks
    def getTaskForTarget(fileName)
      @taskHash.each_value do |task|
        return task if (task.targets and task.targets.include?(fileName))
      end
      nil
    end


    def hasConfig?(name)
      return @configs.has_key?(name)
    end


    def addConfig(config)
      Makr.log.warn("Overwriting config with name " + config.name) if hasConfig?(config.name)
      @configs[config.name] = config
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
      if hasConfig?(name) then # already have this config
        config = getConfig(name)
      else
        parentName = task.config.name if task.config
        config = makeNewConfig(name, parentName)
      end
      return task.config = config
    end


    # dump helper functions


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
        deleteArr.concat(task.dependantTasks) # pickup dependantTasks, which need to be deleted, too
        task.cleanupBeforeDeletion() # do last cleanups
        task.clearAll()  # untie all connections
      end
    end


    def cleanConfigs()
      saveHash = Hash.new
      @taskHash.each do |key, value|
        if value.config and not (saveHash.has_key?(value.config.name)) then # save each config once
          saveHash[value.config.name] = @configs[value.config.name]
          @configs.delete(value.config.name)
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

  end  # end of class Build



  # Constructs a build from the caches found in the ".makr"-subDir in the given buildPath, if they
  # exist. Otherwise makes everything new (dirs and Build object). In either case, a Build object
  # is returned.
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
      build.cleanTaskHashCache()
      return build
    end
  end


  # Saves the Build to the ".makr"-subdir of the buildPath. 
  def Makr.saveBuild(build, cleanupConfigs = true)
    # we exclude the fileHash from the saved data (as it is just convenience and we want to avoid a synchronization mess)
    localFileHash = build.fileHash
    build.fileHash = Hash.new
    build.cleanConfigs() if cleanupConfigs
    build.prepareDump() # exchanges task hashes so that upon load all that is now in taskHash is then in taskHashCache
    saveFileName = build.buildPath + "/.makr/build.ruby_marshal_dump"
    File.open(saveFileName, "wb") do |dumpFile|
      Marshal.dump(build, dumpFile)
    end

    # as the user may use the build after save, we restore everything
    build.unprepareDump() 
    build.fileHash = localFileHash
  end







  # This class realizes the multi-threaded update step.
  # It can be used stand-alone, but typically calling Build::build() is the standard way to do it.
  class UpdateTraverser

    # this class variable is used to realize cooperative build abort, see Makr::abortBuild()
    @@abortBuild = false
    def UpdateTraverser.abortBuild
      @@abortBuild
    end
    def UpdateTraverser.abortBuild=(arg)
      @@abortBuild = arg
    end

    # we use this to provide a countdown functionality for a parallel build in the log output
    # similar to what cmake provides with a percentage upcount. We count down the number of tasks
    # that need to be done, so its always correct in the sense that it comes down to zero at the
    # end of a build
    # ( see references to UpdateTraverser.timeToBuildDownRemaining at the end of this script to see how the
    #  output is generated )
    @@timeToBuildDownRemaining = 0
    def UpdateTraverser.timeToBuildDownRemaining
      @@timeToBuildDownRemaining
    end
    def UpdateTraverser.timeToBuildDownRemaining=(arg)
      @@timeToBuildDownRemaining = arg
    end
    @@timeToBuildDownRemainingMutex = Mutex.new
    def UpdateTraverser.timeToBuildDownRemainingMutex
      @@timeToBuildDownRemainingMutex
    end


    # nested class representing a single task update, executed in a thread pool
    class Updater

      def initialize(task, threadPool, stopOnFirstError)
        @task = task
        @threadPool = threadPool
        @stopOnFirstError = stopOnFirstError
      end

      def collectChildState(task) # returns empty string if task has no childs
        retString = String.new
        localTaskArray = task.dependencies.sort {|t1, t2| t1.name <=> t2.name}
        localTaskArray.each do |dep|
          retString += dep.state
        end
        return retString
      end

      # we need to go up the tree with the traversal even in case dependency did not update or had an error upon update
      # just to increase the dependenciesUpdatedCount in each marked node so that in case
      # of the update of a single (sub-)child, the node will surely be updated or an update error is handled!
      # An intermediate node up to the root might not be updated, as it need not, but the algorithm logic
      # still needs to handle dependant tasks for the above reason.
      def run()
        @task.mutex.synchronize do
          raise "[makr] Unexpectedly starting on a task that needs no update!" if not @task.updateMark # some sanity check
          @task.updateMark = false
          daDoRunRunRun() # see immediately below
        end
      end

      def daDoRunRunRun()
        # as we will have done a task (wether it was updated or not doesnt matter), we want to decrease the timeToBuildDownRemaining
        # we scale by the nrOfThreads employed (ok, this is not a linear speedup, but close to it). As we decrease in parallel, we
        # need the mutex here.
        UpdateTraverser.timeToBuildDownRemainingMutex.synchronize do
          UpdateTraverser.timeToBuildDownRemaining -= @task.updateDuration / @threadPool.nrOfThreads
        end

        if @task.updateError then

          @task.handleUpdateError()
          @task.dependantTasks.each do |dependantTask|
            dependantTask.updateError = true if dependantTask.updateMark
          end

        else

          childState = collectChildState(@task)
          # do we need to update?
          if (@task.dependencies.empty? or (childState != @task.state)) and not UpdateTraverser.abortBuild then
            # we update expected duration when task is updated, so that only the last measured time is used the next time
            t1 = Time.now
            # we always delete targets before update, Task classes that do not want this, should overwrite the function
            @task.deleteTargetsBeforeUpdate()
            successfulUpdate = @task.update()
            @task.updateDuration = (Time.now - t1)

            unless successfulUpdate then
              @task.dependantTasks.each do |dependantTask|
                dependantTask.updateError = true if dependantTask.updateMark
              end
              UpdateTraverser.abortBuild = true if @stopOnFirstError
            else
              # we only set child state on inner nodes and if the update was successful (leaf nodes set their state themselves)
              @task.state = collectChildState(@task) if (not @task.dependencies.empty?)
            end
          end

        end

        @task.dependantTasks.each do |dependantTask|
          dependantTask.mutex.synchronize do
            if dependantTask.updateMark then # only work on dependant tasks that want to be updated
              # if we are the last thread to reach the dependant task, we will run the next thread on it
              dependantTask.dependenciesUpdatedCount = dependantTask.dependenciesUpdatedCount + 1
              if (dependantTask.dependenciesUpdatedCount == dependantTask.dependencies.size) then
                updater = Updater.new(dependantTask, @threadPool, @stopOnFirstError)
                @threadPool.execute {updater.run()}
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
    def traverse(build, root)
      build.resetUpdateMarks()
      # reset the count that represents the nr of tasks that are affected by this update
      @@timeToBuildDownRemaining = 0.0
      collectedTasksWithNoDeps = Array.new
      recursiveMarkAndCollectTasksWithNoDeps(root, collectedTasksWithNoDeps)
      collectedTasksWithNoDeps.uniq!
      Makr.log.info("collectedTasksWithNoDeps.size: " + collectedTasksWithNoDeps.size.to_s)
      collectedTasksWithNoDeps.each do |noDepsTask|
        updater = Updater.new(noDepsTask, @threadPool, build.stopOnFirstError)
        @threadPool.execute {updater.run()}
      end
      @threadPool.join()
    end


    # internal helper function (see also traverse(root) )
    def recursiveMarkAndCollectTasksWithNoDeps(task, collectedTasksWithNoDeps)
      return if task.updateMark # task was already marked and thus we dont need to descend
      # prepare the task variables upon descend
      task.updateMark = true
      task.dependenciesUpdatedCount = 0
      task.updateError = false
      # each task that we mark gets touched by Updater, so we increase timeToBuildDownRemaining by the
      # number of seconds estimated in previous builds (see Updater.run)
      # we scale by the nrOfThreads employed (ok, this is not a linear speedup, but close to it)
      @@timeToBuildDownRemaining += task.updateDuration / @threadPool.nrOfThreads

      # then collect, if no further deps or recurse
      if task.dependencies.empty? then
        collectedTasksWithNoDeps.push(task)
        return
      end
      task.dependencies.each{|dep| recursiveMarkAndCollectTasksWithNoDeps(dep, collectedTasksWithNoDeps)}
    end

  end













  # build construction helper classes


  # Helps collecting files given directories and patterns. All methods are static.
  # I did not use find from ruby standard library, as I needed more flexibility (patterns,
  # non-recursive directory lists, etc.)
  class FileCollector


    # dirName is expected to be a path name, pattern could be "*" or "*.cpp" or "*.{cpp,cxx,CPP}", etc.
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


    # additional collector with exclusion pattern given
    def FileCollector.collectExclude(dirName, pattern, exclusionPattern, recurse = true)
      fileCollection = Array.new
      privateCollect(dirName, pattern, exclusionPattern, fileCollection, recurse)
      return fileCollection
    end


  protected


    def FileCollector.privateCollect(dirName, pattern, exclusionPattern, fileCollection, recurse)

      return if UpdateTraverser.abortBuild # check if build was aborted before proceeding

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
      Makr.cleanPathName(fileName)
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
      # now fill fileHash
      @build.fileHash[fileName] = Array.new if not @build.fileHash[fileName]
      @build.fileHash[fileName].push(localTask)
      @build.fileHash[fileName].uniq!
      return [localTask]
    end
  end




  # Can be called with an array of file names in fileCollection (as produced by FileCollector) or just a single file name.
  # On each file in fileCollection, all generators from generatorArray are executed. During this (maybe lengthy) operation,
  # the build could be aborted (for example by user request or fatal generator error). This function returns an array of
  # tasks that can be used to construct a DynamicLibTask or StaticLibTask or ProgramTask, etc.
  def Makr.applyGenerators(fileCollection, generatorArray)
    # first check, if we only have a single file
    fileCollection = [Makr.cleanPathName(fileCollection)] if fileCollection.kind_of? String
    tasks = Array.new
    fileCollection.each do |fileName|
      generatorArray.each do |gen|
        return tasks if UpdateTraverser.abortBuild # cooperatively abort build
        genTasks = gen.generate(fileName)
        tasks.concat(genTasks)
      end
    end
    return tasks
  end
















  # script argument management (facility for calling sub-Makrfiles)

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
      Makr.log.fatal("In Makr.popArgs(): tried to remove the last arguments from stack, exiting!")
      Makr.abortBuild()
    end
    ScriptArgumentsStorage.get.pop
  end


  def Makr.getArgs()
    ScriptArgumentsStorage.get.last
  end









  # loads a Makrfile.rb from the given dir and executes it using Kernel.load and push/pops the current ScriptArguments, so that they are save
  def Makr.makeDir(dir)
    return if UpdateTraverser.abortBuild # check if build was aborted before proceeding
    Makr.cleanPathName(dir)
    oldDir = Dir.pwd
    Dir.chdir(dir)
    makrFilePath = "./Makrfile.rb"
    if File.exist?(makrFilePath) then
      Makr.pushArgs(Makr::ScriptArguments.new(makrFilePath, getArgs().arguments.clone))
      Kernel.load(makrFilePath, true)  # second parameter sayz to wrap an anonymous module around the called script content
      popArgs()
    else
      Makr.log.fatal("Cannot find Makrfile-Path " + makrFilePath + " from current working dir " + Dir.pwd + "!")
      Makr.abortBuild()
    end
    Dir.chdir(oldDir)
  end





  # very simple extension system (plugin system)
  def Makr.loadExtension(exName)
    Kernel.load($makrExtensionsDir + "/" + exName + ".rb")
  end





end     # end of module makr ######################################################################################








####################################################################################################################

# MAIN logic and interface with client code following

####################################################################################################################

# first start logger and set start logging level (can of course be changed by user)
Makr.log.level = Logger::DEBUG
Makr.log.formatter = proc { |severity, datetime, progname, msg|
    "[makr #{severity} #{datetime}] [#{Makr::UpdateTraverser.timeToBuildDownRemaining}]    #{msg}\n"
}
Makr.log << "\n\nmakr version 1.1\n\n"  # just give short version notice on every startup

# then set the signal handler to allow cooperative aborting of the build process on SIGUSR1 or SIGTERM
abort_handler = Proc.new do
  puts Makr.log.fatal("Aborting build on signal USR1 or TERM")
  Makr.abortBuild()
end
Signal.trap("USR1", abort_handler)
Signal.trap("TERM", abort_handler)


# set global vars

# for the following variable, we care for symlinks only, hardlinks will go wrong
# (TODO: maybe we need an environment var here or something hardcoded in this file?)
unless File.symlink?(__FILE__) then
  $makrDir = File.dirname(__FILE__)
else
  makrLinkPath = File.readlink(__FILE__) # makrLinkPath can be absolute or relative!
  if makrLinkPath.index('/') == 0 then
    $makrDir = File.dirname(makrLinkPath)
  else
    $makrDir = File.dirname(__FILE__) + "/" + File.dirname(makrLinkPath)
  end
end
$makrExtensionsDir = $makrDir + "/extensions"


# we need a basic ScriptArguments object pushed to stack (kind of dummy holding ARGV)
# we use a relative path here to allow moving of build dir
Makr.pushArgs(Makr::ScriptArguments.new("./Makrfile.rb", ARGV))
# then we reuse the makeDir functionality building the current directory
Makr.makeDir(".")

