
module Makr



  # Convenience class related to Config creation providing only file names
  #
  # can be used like this:
  #
  #       myConfig = SimpleConfig.new( ["/usr/include/xorg", "/usr/include/freetype2"],    # includes
  #                                    ["png", "GL", "QtCore"],                             # libs
  #                                    ["/usr/lib64/openvpn"]                             # libPaths
  #                                  ).makeConfig("MyConfigName")
  #
  #       # this is optional, but allows getting the config by name with build.getConfig("MyConfigName") later
  #       build.addConfig(myConfig)
  #
  #
  #
  #
  # or like this: (if you dont want to remember the argument order, using a hash)
  #
  #       myConfig = SimpleConfig.new( { "includes" => ["/usr/include/xorg","/usr/include/freetype2"],
  #                                      "libs"     => ["png","GL","QtCore"],
  #                                      "libPaths" => ["/usr/lib64/openvpn"]
  #                                    }
  #                                  ).makeConfig("MyConfigName")
  #
  #       # this is optional, but allows getting the config by name with build.getConfig("MyConfigName") later
  #       build.addConfig(myConfig)
  #
  #
  #
  # The default compiler used here is "g++"
  class SimpleConfig

    # these are expected to be Array of String
    attr_accessor :includePaths, :libs, :libPaths

    def initialize(includePaths, libs, libPaths = Array.new)
      @includePaths = includePaths
      @libs = libs
      @libPaths = libPaths
    end

    def initialize(hash)
      @includePaths = hash["includePaths"]
      @libs = hash["libs"]
      @libPaths = hash["libPaths"]
    end

    def makeConfig(name)
      config = Config.new(name)
      config["compiler"] = "g++"
      config["compiler.includePaths"] = String.new
      includePaths.each do |incPath|
        config["compiler.includePaths"] += " -I" + incPath
      end
      config["compiler.libs"] = String.new
      libs.each do |libName|
        config["compiler.libs"] += " -l" + libName
      end
      config["compiler.libPaths"] = String.new
      includePaths.each do |libPath|
        config["compiler.libPaths"] += " -L" + libPath
      end
      return config
    end


  end


  # can be used like SimpleConfig, just that it inserts "gcc" as compiler
  class SimpleConfigC < SimpleConfig

    def makeConfig(name)
      super
      config["compiler"] = "gcc"
      return config
    end

  end


end

