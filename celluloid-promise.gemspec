# -*- encoding: utf-8 -*-
$:.push File.expand_path("../lib", __FILE__)
require "celluloid-promise/version"

Gem::Specification.new do |s|
  s.name        = "celluloid-promise"
  s.version     = Celluloid::Promise::VERSION

  s.platform    = Gem::Platform::RUBY
  s.authors     = ["Stephen von Takach"]
  s.email       = ["steve@cotag.me"]
  s.homepage    = "https://github.com/cotag/celluloid-promise"
  s.summary     = "Celluloid based multi-threaded promise implementation"
  s.description = s.summary

  s.add_dependency "celluloid"
  s.add_development_dependency "rspec"
  s.add_development_dependency "atomic"

  s.files = Dir["{lib}/**/*"] + ["MIT-LICENSE", "Rakefile", "README.textile"]
  s.test_files = Dir["spec/**/*"]
  s.require_paths = ["lib"]
end
