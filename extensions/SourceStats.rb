

module Makr








  # calculates various statistics about source files and produces a statistix file
  class SourceStatTask < Task

    @@statsFile = File.new("SourceStats.txt")

    # input source file
    attr_reader :fileName


    # make a unique name for a MocTask out of the given fileName
    def SourceStatTask.makeName(fileName)
      "SourceStatTask__" + fileName
    end


    # config is unused right now
    def initialize(fileName, build, config = nil)
      @fileName = Makr.cleanPathName(fileName)
      # now we need a unique name for this task
      super(SourceStatTask.makeName(@fileName), config)

      # first we need a dep on the input file
      if not build.hasTask?(@fileName) then
        @inputFileDep = FileTask.new(@fileName)
        build.addTask(@fileName, @inputFileDep)
      else
        @inputFileDep = build.getTask(@fileName)
      end
      addDependency(@inputFileDep)

      Makr.log.debug("made SourceStatTask with @name=\"" + @name + "\"")
    end


    def update()
      # determine various stats about the source file
      sourceLines = IO.readlines(@fileName)
      @locCount = 0
      sourceLines.each do |line|
        @locCount += 1 if line.strip.empty?
      end
      @@statsFile.append(@fileName + " LOC: " + @locCount) this is too simple but gives the idea
      return true
    end


    # this task wants to be deleted if the file no longer contains the Q_OBJECT macro (TODO is this correct?)
    def mustBeDeleted?()
      return (not File.exists?(@fileName))
    end

  end


















  # Produces a UicTask for every fileName given
  class SourceStatTaskGenerator

    def initialize(build)
      @build = build
    end


    def generate(fileName)
      Makr.cleanPathName(fileName)
      sourceStatTaskName = SourceStatTask.makeName(fileName)
      if not @build.hasTask?(sourceStatTaskName) then
        sourceStatTask = SourceStatTask.new(fileName, @build, nil)
        @build.addTask(sourceStatTaskName, sourceStatTask)
      end
      sourceStatTask = @build.getTask(sourceStatTaskName)
      tasks = [sourceStatTask]
      # now fill fileHash
      @build.fileHash[fileName] ||= Array.new
      @build.fileHash[fileName].concat(tasks)
      @build.fileHash[fileName].uniq!
      return tasks
    end

  end









end     # end of module makr ######################################################################################



