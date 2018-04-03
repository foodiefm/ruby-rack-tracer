require 'opentracing'

module Rack
  class Tracer
    REQUEST_URI = 'REQUEST_URI'.freeze
    REQUEST_METHOD = 'REQUEST_METHOD'.freeze

    # Create a new Rack Tracer middleware.
    #
    # @param app The Rack application/middlewares stack.
    # @param tracer [OpenTracing::Tracer] A tracer to be used when start_span, and extract
    #        is called.
    # @param on_start_span [Proc, nil] A callback evaluated after a new span is created.
    # @param errors [Array<Class>] An array of error classes to be captured by the tracer
    #        as errors. Errors are **not** muted by the middleware, they're re-raised afterwards.
    def initialize(app, on_start_span: nil, trust_incoming_span: true, errors: [StandardError])
      @app = app
      @on_start_span = on_start_span
      @trust_incoming_span = trust_incoming_span
      @errors = errors
    end

    def call(env)
      method = env[REQUEST_METHOD]

      context = OpenTracing.global_tracer
                  .extract(OpenTracing::FORMAT_RACK, env) if @trust_incoming_span
      span = OpenTracing.global_tracer.start_span(method,
        child_of: context,
        tags: {
          'component' => 'rack',
          'span.kind' => 'server',
          'http.method' => method,
          'http.url' => env[REQUEST_URI],
          'http.uri' => env[REQUEST_URI] # For zipkin, not OT convention
        }
      )

      @on_start_span.call(span) if @on_start_span

      env['rack.span'] = span

      @app.call(env).tap do |status_code, _headers, _body|
        span.set_tag('http.status_code', status_code)

        if route = route_from_env(env)
          span.set_tag('route', route)
        end
      end
    rescue *@errors => e
      span.set_tag('error', true)
      span.log(event: 'error', :'error.object' => e)
      raise
    ensure
      span.finish
    end

    private

    def route_from_env(env)
      if route = env['sinatra.route']
        route.split(' ').last
      end
    end
  end
end
