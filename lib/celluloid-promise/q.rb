module Celluloid
	module Promise

		#
		# Used to serialise the chaining of promises on a thread
		# Allowing the promise to safely be called on any other thread
		#
		class Reactor
			include ::Celluloid
			
			def task
				yield if block_given?
			end
		end
		
		
		
		# @abstract
		class Promise
			private_class_method :new
		end
		
		
		#
		# A new promise instance is created when a deferred instance is created and can be
		# retrieved by calling deferred.promise
		#
		class DeferredPromise < Promise
			public_class_method :new
			
			def initialize(defer, reactor)
				raise ArgumentError unless defer.is_a?(Deferred)
				super()
				
				@defer = defer
				@reactor = reactor
			end
			
			#
			# regardless of when the promise was or will be resolved / rejected, calls one of
			# the success or error callbacks asynchronously as soon as the result is available.
			# The callbacks are called with a single argument, the result or rejection reason.
			#
			# @param [Proc, Proc, &blk] callbacks success, error, success_block
			# @return [Promise] Returns an unresolved promise for chaining
			def then(callback = nil, errback = nil, &blk)
				result = Q.defer
				
				callback ||= blk
				
				wrappedCallback = proc { |val|
					begin
						if callback.nil?
							result.resolve(val)
						else
							result.resolve(callback.call(val))
						end
					rescue => e
						#warn "\nUnhandled exception: #{e.message}\n#{e.backtrace.join("\n")}\n"
						result.reject(e);
					end
				}
				
				wrappedErrback = proc { |reason|
					begin
						if errback.nil?
							result.resolve(ResolvedPromise.new(@reactor, reason, true))
						else
							result.resolve(errback.call(reason))
						end
					rescue => e
						#warn "Unhandled exception: #{e.message}\n#{e.backtrace.join("\n")}\n"
						result.reject(e);
					end
				}
				
				#
				# Schedule as we are touching shared state
				#	Everything else is locally scoped
				#
				@reactor.async.task do
					pending_array = pending
					
					if pending_array.nil?
						value.then(wrappedCallback, wrappedErrback)
					else
						pending_array << [wrappedCallback, wrappedErrback]
					end
				end
				
				result.promise
			end
			
			
			private
			
			
			def pending
				@defer.instance_eval { @pending }
			end
			
			def value
				@defer.instance_eval { @value }
			end
		end
		
		
		class ResolvedPromise < Promise
			public_class_method :new
			
			def initialize(reactor, response, error = false)
				raise ArgumentError if error && response.is_a?(Promise)
				super()
				
				@error = error
				@response = response
				@reactor = reactor
			end
			
			def then(callback = nil, errback = nil, &blk)
				result = Q.defer
				
				callback ||= blk
				
				@reactor.async.task do
					if @error
						if errback.nil?
							result.resolve(ResolvedPromise.new(@reactor, @response, true))
						else
							result.resolve(errback.call(@response))
						end
					else
						if callback.nil?
							result.resolve(@response)
						else
							result.resolve(callback.call(@response))
						end
					end
				end
				
				result.promise
			end
		end
		
		
		
		#
		# The purpose of the deferred object is to expose the associated Promise instance as well
		# as APIs that can be used for signalling the successful or unsuccessful completion of a task.
		#
		class Deferred
			
			def initialize(reactor)
				super()
				
				@reactor = reactor
				@pending = []
				@value = nil
			end
			
			#
			# resolves the derived promise with the value. If the value is a rejection constructed via
			# Q.reject, the promise will be rejected instead.
			#
			# @param [Object] val constant, message or an object representing the result.
			def resolve(val = nil)
				@reactor.async.task do
					if not @pending.nil?
						callbacks = @pending
						@pending = nil
						@value = ref(val)
						
						if callbacks.length > 0
							callbacks.each do |callback|
								@value.then(callback[0], callback[1])
							end
						end
					end
				end
			end
			
			#
			# rejects the derived promise with the reason. This is equivalent to resolving it with a rejection
			# constructed via Q.reject.
			#
			# @param [Object] reason constant, message, exception or an object representing the rejection reason.
			def reject(reason = nil)
				resolve(ResolvedPromise.new(@reactor, reason, true))
			end
			
			#
			# Creates a promise object associated with this deferred
			#
			def promise
				DeferredPromise.new( self, @reactor )
			end
			
			
			private
			
			
			def ref(value)
				return value if value.is_a?(Promise)
				return ResolvedPromise.new( @reactor, value )			# A resolved success promise
			end
		end
		
		
		class Coordinator
			include ::Celluloid
			

			def initialize
				@reactors = []
				@current = -1	# So we pick 0 first
				threads = ::Celluloid.cores
				threads += 1 if threads == 1
				threads.times { @reactors << Reactor.new_link }	# Have a thread for each core and link promises to each thread for serialisation 
			end
			

			#
			# Creates a Deferred object which represents a task which will finish in the future.
			#
			# @return [Deferred] Returns a new instance of Deferred
			def defer
				return Deferred.new(next_reactor)
			end
			

			#
			# Creates a promise that is resolved as rejected with the specified reason. This api should be
			# used to forward rejection in a chain of promises. If you are dealing with the last promise in
			# a promise chain, you don't need to worry about it.
			#
			# When comparing deferreds/promises to the familiar behaviour of try/catch/throw, think of
			# reject as the raise keyword in Ruby. This also means that if you "catch" an error via
			# a promise error callback and you want to forward the error to the promise derived from the
			# current promise, you have to "rethrow" the error by returning a rejection constructed via
			# reject.
			#
			# @example handling rejections
			#
			#   #!/usr/bin/env ruby
			#
			#   require 'rubygems' # or use Bundler.setup
			#   require 'celluloid-promise'
			#
			#   promiseB = promiseA.then(lambda {|result|
			#     # success: do something and resolve promiseB with the old or a new result
			#     return result
			#   }, lambda {|reason|
			#     # error: handle the error if possible and resolve promiseB with newPromiseOrValue,
			#     #        otherwise forward the rejection to promiseB
			#     if canHandle(reason)
			#       # handle the error and recover
			#       return newPromiseOrValue
			#     end
			#     return Q.reject(reason)
			#   })
			#
			# @param [Object] reason constant, message, exception or an object representing the rejection reason.
			# @return [Promise] Returns a promise that was already resolved as rejected with the reason
			def reject(reason = nil)
				return ResolvedPromise.new(next_reactor, reason, true)	# A resolved failed promise
			end


			#
			# Combines multiple promises into a single promise that is resolved when all of the input
			# promises are resolved.
			#
			# @param [*Promise] Promises a number of promises that will be combined into a single promise
			# @return [Promise] Returns a single promise that will be resolved with an array of values,
			#   each value corresponding to the promise at the same index in the `promises` array. If any of
			#   the promises is resolved with a rejection, this resulting promise will be resolved with the
			#   same rejection.
			def all(*promises)
				reactor = next_reactor
				deferred = Deferred.new(reactor)
				counter = promises.length
				results = []
				
				if counter > 0
					promises.each_index do |index|
						ref(promises[index], reactor).then(proc {|result|
							if results[index].nil?
								results[index] = result
								counter -= 1
								deferred.resolve(results) if counter <= 0
							end
							result
						}, proc {|reason|
							if results[index].nil?
								deferred.reject(reason)
							end
							reason
						})
					end
				else
					deferred.resolve(results)
				end
				
				return deferred.promise
			end
			
			
			private


			def ref(value, reactor)
				return value if value.is_a?(Promise)
				return ResolvedPromise.new( reactor, value )		# A resolved success promise
			end
			
			
			#
			# Promises are placed on reactor threads in a round robin
			# I would have used pool however Celluloid::IO allows us to run
			# multiple concurrent promise chains on each reactor, pool can't.
			#
			def next_reactor
				@current = @current >= (@reactors.length - 1) ? 0 : @current + 1
				selected = @reactors[@current]
				selected != Celluloid::Actor.current ? selected : next_reactor
			end
		end
	end

	#
	# This is the primary interface for creating promises
	# The coordinator selects the reactor for the current promise chain
	#
	Promise::Coordinator.supervise_as :Q
	module Q
		def self.defer
			Actor[:Q].defer
		end
		
		def self.reject(reason = nil)
			Actor[:Q].reject(reason)
		end

		def self.all(*promises)
			Actor[:Q].all(*promises)
		end
	end
end
