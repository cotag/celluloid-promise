require 'rubygems'
require 'bundler/setup'

require 'celluloid-promise'
require 'atomic'



describe Celluloid::Q do

	before :all do
		@defer = Celluloid::Promise::Reactor.pool
	end

	before :each do
		@deferred = Celluloid::Q.defer
		@promise = @deferred.promise
		@log = []
		@finish = proc {
			while(!@mutex.try_lock); end
			@resource.signal
			@mutex.unlock
		}
		@default_fail = proc { |reason|
			fail(reason)
			@finish.call
		}
		@mutex = Mutex.new
		@resource = ConditionVariable.new
	end



	describe Celluloid::Promise::Coordinator do
		
		
		describe 'resolve' do
			
			
			it "should call the callback in the next turn" do
				@mutex.synchronize {
					@promise.then(proc {|result|
						@log << result
						@finish.call
					}, @default_fail)
					
					@deferred.resolve(:foo)
					@resource.wait(@mutex)
				}
				
				@log.should == [:foo]
			end
			
			
			it "should fulfill success callbacks in the registration order" do
				@mutex.synchronize {
					@promise.then(proc {|result|
						@log << :first
					}, @default_fail)
					
					@promise.then(proc {|result|
						@log << :second
						@finish.call
					}, @default_fail)

					@deferred.resolve(:foo)
					@resource.wait(@mutex)
				}
				
				@log.should == [:first, :second]
			end
			
			
			it "should do nothing if a promise was previously resolved" do
				@mutex.synchronize {
					@promise.then(proc {|result|
						@log << result
						@log.should == [:foo]
						@deferred.resolve(:bar)
						@finish.call
					}, @default_fail)
					
					@deferred.resolve(:foo)
					@deferred.reject(:baz)
					@resource.wait(@mutex)
				}
				
				@log.should == [:foo]
			end
			

			it "should allow deferred resolution with a new promise" do
				deferred2 = Celluloid::Q.defer
				@mutex.synchronize {
					@promise.then(proc {|result|
						result.should == :foo
						@finish.call
					}, @default_fail)
					
					@deferred.resolve(deferred2.promise)
					deferred2.resolve(:foo)

					@resource.wait(@mutex)
				}
			end
			
			
			it "should not break if a callbacks registers another callback" do
				@mutex.synchronize {
					@promise.then(proc {|result|
						@log << :outer
						@promise.then(proc {|result|
							@log << :inner
							@finish.call
						}, @default_fail)
					}, @default_fail)
					
					@deferred.resolve(:foo)
					
					@resource.wait(@mutex)
					@log.should == [:outer, :inner]
				}
			end


			it "can modify the result of a promise before returning" do
				@mutex.synchronize {
					proc { |name|
						@defer.async.perform {
							@deferred.resolve("Hello #{name}")
						}
						@promise.then(proc {|result|
							result.should == 'Hello Robin Hood'
							result += "?"
							result
						})
					}.call('Robin Hood').then(proc { |greeting|
						greeting.should == 'Hello Robin Hood?'
						@finish.call
					}, @default_fail)

					@resource.wait(@mutex)
				}
			end
			
		end



		describe 'reject' do
			it "should reject the promise and execute all error callbacks" do
				@mutex.synchronize {
					@promise.then(@default_fail, proc {|result|
						@log << :first
					})
					@promise.then(@default_fail, proc {|result|
						@log << :second
						@finish.call
					})
					
					@deferred.reject(:foo)
					
					@resource.wait(@mutex)
				}

				@log.should == [:first, :second]
			end
			
			
			it "should do nothing if a promise was previously rejected" do
				@mutex.synchronize {
					@promise.then(@default_fail, proc {|result|
						@log << result
						@log.should == [:baz]
						@deferred.resolve(:bar)

						@finish.call
					})
					
					@deferred.reject(:baz)
					@deferred.resolve(:foo)
					

					@resource.wait(@mutex)
				}

				@log.should == [:baz]
			end
			
			
			it "should not defer rejection with a new promise" do
				deferred2 = Celluloid::Q.defer
				@promise.then(@default_fail, @default_fail)
				begin
					@deferred.reject(deferred2.promise)
				rescue => e
					e.is_a?(ArgumentError).should == true
				end
			end

			
			it "should package a string into a rejected promise" do
				@mutex.synchronize {
					rejectedPromise = Celluloid::Q.reject('not gonna happen')
					
					@promise.then(nil, proc {|reason|
						@log << reason
						@finish.call
					})
					
					@deferred.resolve(rejectedPromise)
					
					@resource.wait(@mutex)
					@log.should == ['not gonna happen']
				}
			end
			
			
			it "should return a promise that forwards callbacks if the callbacks are missing" do
				@mutex.synchronize {
					rejectedPromise = Celluloid::Q.reject('not gonna happen')
					
					@promise.then(nil, proc {|reason|
						@log << reason
						@finish.call
					})
					
					@deferred.resolve(rejectedPromise.then())
					
					@resource.wait(@mutex)
					@log.should == ['not gonna happen']
				}
			end
			
		end


		describe 'all' do
			
			it "should resolve all of nothing" do
				@mutex.synchronize {
					Celluloid::Q.all.then(proc {|result|
						@log << result
						@finish.call
					}, @default_fail)
					

					@resource.wait(@mutex)
				}

				@log.should == [[]]
			end
			
			it "should take an array of promises and return a promise for an array of results" do
				@mutex.synchronize {
					deferred1 = Celluloid::Q.defer
					deferred2 = Celluloid::Q.defer
					
					Celluloid::Q.all(@promise, deferred1.promise, deferred2.promise).then(proc {|result|
						result.should == [:foo, :bar, :baz]
						@finish.call
					}, @default_fail)
					
					@defer.async.perform { @deferred.resolve(:foo) }
					@defer.async.perform { deferred2.resolve(:baz) }
					@defer.async.perform { deferred1.resolve(:bar) }

					@resource.wait(@mutex)
				}
			end
			
			
			it "should reject the derived promise if at least one of the promises in the array is rejected" do
				@mutex.synchronize {
					deferred1 = Celluloid::Q.defer
					deferred2 = Celluloid::Q.defer
					
					Celluloid::Q.all(@promise, deferred1.promise, deferred2.promise).then(@default_fail, proc {|reason|
						reason.should == :baz
						@finish.call
					})
					
					@defer.async.perform { @deferred.resolve(:foo) }
					@defer.async.perform { deferred2.reject(:baz) }

					@resource.wait(@mutex)
				}
			end
			
		end

	end


	describe Celluloid::Promise do

		describe 'then' do
				
			it "should allow registration of a success callback without an errback and resolve" do
				@mutex.synchronize {
					@promise.then(proc {|result|
						@log << result
					})
					@promise.then(proc {
						@finish.call
					}, @default_fail)

					@deferred.resolve(:foo)
					
					@resource.wait(@mutex)
					@log.should == [:foo]
				}
			end
			
			
			it "should allow registration of a success callback without an errback and reject" do
				@mutex.synchronize {
					@promise.then(proc {|result|
						@log << result
					})
					@promise.then(@default_fail, proc {
						@finish.call
					})

					@deferred.reject(:foo)
					
					@resource.wait(@mutex)
					@log.should == []
				}
			end
			
			
			it "should allow registration of an errback without a success callback and reject" do
				@mutex.synchronize {
					@promise.then(nil, proc {|reason|
						@log << reason
					})
					@promise.then(@default_fail, proc {
						@finish.call
					})

					@deferred.reject(:foo)
					
					@resource.wait(@mutex)
					@log.should == [:foo]
				}
			end
			
			
			it "should allow registration of an errback without a success callback and resolve" do
				@mutex.synchronize {
					@promise.then(nil, proc {|reason|
						@log << reason
					})
					@promise.then(proc {
						@finish.call
					}, @default_fail)

					@deferred.resolve(:foo)
					
					@resource.wait(@mutex)
					@log.should == []
				}
			end
			
			
			it "should resolve all callbacks with the original value" do
				@mutex.synchronize {
					@promise.then(proc {|result|
						@log << result
						:alt
					}, @default_fail)
					@promise.then(proc {|result|
						@log << result
						nil
					}, @default_fail)
					@promise.then(proc {|result|
						@log << result
						Celluloid::Q.reject('some reason')
					}, @default_fail)
					@promise.then(proc {|result|
						@log << result
						raise 'some error'
					}, @default_fail)
					@promise.then(proc {
						@finish.call
					}, @default_fail)
					
					@deferred.resolve(:foo)
					
					@resource.wait(@mutex)
					@log.should == [:foo, :foo, :foo, :foo]
				}
			end
			
			
			it "should reject all callbacks with the original reason" do
				@mutex.synchronize {
					@promise.then(@default_fail, proc {|result|
						@log << result
						:alt
					})
					@promise.then(@default_fail, proc {|result|
						@log << result
						nil
					})
					@promise.then(@default_fail, proc {|result|
						@log << result
						Celluloid::Q.reject('some reason')
					})
					@promise.then(@default_fail, proc {|result|
						@log << result
						raise 'some error'
					})
					@promise.then(@default_fail, proc {|result|
						@finish.call
					})
					
					@deferred.reject(:foo)
					
					@resource.wait(@mutex)
					@log.should == [:foo, :foo, :foo, :foo]
				}
			end
			
			
			it "should propagate resolution and rejection between dependent promises" do
				@mutex.synchronize {
					@promise.then(proc {|result|
						@log << result
						:bar
					}, @default_fail).then(proc {|result|
						@log << result
						raise 'baz'
					}, @default_fail).then(@default_fail, proc {|result|
						@log << result.message
						raise 'bob'
					}).then(@default_fail, proc {|result|
						@log << result.message
						:done
					}).then(proc {|result|
						@log << result
						@finish.call
					}, @default_fail)
					
					@deferred.resolve(:foo)
					
					@resource.wait(@mutex)
					@log.should == [:foo, :bar, 'baz', 'bob', :done]
				}
			end
			
			
			it "should call error callback even if promise is already rejected" do
				@mutex.synchronize {
					@deferred.reject(:foo)
					
					@promise.then(nil, proc {|reason|
						@log << reason
						@finish.call
					})
					
					@resource.wait(@mutex)
					@log.should == [:foo]
				}
			end
			
			
			class BlockingActor
				include ::Celluloid
				
				def delayed_response
					sleep (5..10).to_a.sample
				end
			end
			
			
			it "should not block when waiting for other promises to finish" do
				@mutex.synchronize {
					
					actor = BlockingActor.new
					count = Atomic.new(0)
					cores = ::Celluloid.cores
					deferreds = cores * 2
					deferred_store = []
					
					args = [proc {|val|
						actor.delayed_response
						count.update {|v| v + 1}
					}, @default_fail]
					
					
					deferreds.times {
						defer = Celluloid::Q.defer
						defer.promise.then(*args)
						deferred_store << defer
						defer.resolve()
					}
					
					@promise.then(proc {|result|
						(!!(count.value < cores)).should == true
						@finish.call
					}, @default_fail)
					
					
					@deferred.resolve()
					@resource.wait(@mutex)
					
					actor.terminate
					::Celluloid::Actor.kill(actor)
				}
			end
			
		end

	end

end

