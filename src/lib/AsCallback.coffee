ComponentLoader = require('./ComponentLoader').ComponentLoader
Network = require('./Network').Network
internalSocket = require './InternalSocket'
Graph = require('fbp-graph').Graph

normalizeOptions = (options, component) ->
  options = {} unless options
  options.name = component unless options.name
  if not options.baseDir and process and process.cwd
    options.baseDir = process.cwd()
  unless options.loader
    options.loader = new ComponentLoader options.baseDir
  options.network = null
  options

prepareNetwork = (component, options, callback) ->
  return callback null, options.network if options.network
  # Start by loading the component
  options.loader.load component, (err, instance) ->
    return callback err if err
    # Prepare a graph wrapping the component
    graph = new Graph options.name
    nodeName = options.name
    graph.addNode nodeName, component
    # Expose ports
    # FIXME: direct process.component.inPorts/outPorts access is only for legacy compat
    inPorts = instance.inPorts.ports or instance.inPorts
    outPorts = instance.outPorts.ports or instance.outPorts
    for port, def of inPorts
      graph.addInport port, nodeName, port
    for port, def of outPorts
      graph.addOutport port, nodeName, port
    # Prepare network
    graph.componentLoader = options.loader
    options.network = new Network graph, options
    # Wire the network up and start execution
    options.network.connect (err) ->
      return callback err if err
      callback null, options.network

runNetwork = (network, inputs, options, callback) ->
  process = network.getNode options.name
  # Prepare inports
  inPorts = Object.keys network.graph.inports
  inSockets = {}
  inPorts.forEach (inport) ->
    inSockets[inport] = internalSocket.createSocket()
    process.component.inPorts[inport].attach inSockets[inport]
  # Subscribe outports
  received = {}
  outPorts = Object.keys network.graph.outports
  outSockets = {}
  outPorts.forEach (outport) ->
    received[outport] = []
    outSockets[outport] = internalSocket.createSocket()
    process.component.outPorts[outport].attach outSockets[outport]
    outSockets[outport].on 'ip', (ip) ->
      received[outport].push ip
  # Subscribe network finish
  network.once 'end', ->
    # Clear listeners
    for port, socket of outSockets
      process.component.outPorts[port].detach socket
    outSockets = {}
    inSockets = {}
    callback null, received
  # Start network
  network.start (err) ->
    return callback err if err
    # Send inputs
    inSockets[port].send value for port, value of inputs

isMap = (inputs, network) ->
  return false unless typeof inputs is 'object'
  return false unless Object.keys(inputs).length
  for key, value of inputs
    return false unless network.graph.inports[key]
  true

prepareInputMap = (inputs, network) ->
  return inputs if isMap inputs, network
  # Not a map, send to first available inport
  inPort = Object.keys(network.graph.inports)[0]
  # If we have a port named "IN", send to that
  inPort = 'in' if network.graph.inports.in
  map = {}
  map[inPort] = inputs
  return map

normalizeOutput = (values) ->
  datas = values.filter (ip) -> ip.type is 'data'
  if datas.length is 1
    return datas[0].data
  # TODO: Arrayize each stream
  datas.map (ip) -> ip.data

sendOutputMap = (outputs, useMap, callback) ->
  if outputs.error?.length
    # We've got errors
    return callback normalizeOutput outputs.error
  outputKeys = Object.keys outputs
  withValue = outputKeys.filter (outport) ->
    outputs[outport].length > 0
  if withValue.length is 0
    # No output
    return callback null
  if withValue.length is 1 and not useMap
    # Single outport
    callback null, normalizeOutput outputs[withValue[0]]
  result = {}
  for port, packets of outputs
    result[port] = normalizeOutput packets
  callback null, result

exports.asCallback = (component, options) ->
  options = normalizeOptions options, component
  return (inputs, callback) ->
    prepareNetwork component, options, (err, network) ->
      return callback err if err
      useMap = isMap inputs, network
      inputMap = prepareInputMap inputs, network
      runNetwork network, inputMap, options, (err, outputMap) ->
        return callback err if err
        sendOutputMap outputMap, useMap, callback
