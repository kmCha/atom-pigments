{Emitter} = require 'atom'
ColorContext = require './color-context'

module.exports =
class VariablesCollection
  Object.defineProperty @prototype, 'length', {
    get: -> @variables.length
    enumerable: true
  }

  constructor: ->
    @emitter = new Emitter
    @variables = []
    @variableNames = []
    @colorVariables = []
    @variablesByPath = {}
    @dependencyGraph = {}

  onDidChange: (callback) ->
    @emitter.on 'did-change', callback

  getColorVariables: -> @colorVariables

  find: (properties) ->
    keys = Object.keys(properties)
    compare = (k) ->
      if v[k]?.isEqual?
        v[k].isEqual(properties[k])
      else
        v[k] is properties[k]

    for v in @variables
      return v if keys.every(compare)

  add: (variable, batch=false) ->
    [status, previousVariable] = @getVariableStatus(variable)

    switch status
      when 'moved'
        v.range = variable.range
        v.bufferRange = variable.bufferRange
      when 'updated'
        @updateVariable(previousVariable, variable, batch)
      when 'created'
        @createVariable(variable, batch)

  addMany: (variables) ->
    results = {}

    for variable in variables
      res = @add(variable, true)
      if res?
        [status, v] = res

        results[status] ?= []
        results[status].push(v)

    @emitChangeEvent(@updateDependencies(results))

  remove: (variable, batch=false) ->

  removeMany: (variables) ->
    @remove(variable, true) for variable in variables

  getContext: -> new ColorContext(@variables, @colorVariables)

  updateVariable: (previousVariable, variable, batch) ->
    previousVariable.value = variable.value
    previousVariable.range = variable.range
    previousVariable.bufferRange = variable.bufferRange

    @evaluateVariableColor(previousVariable, previousVariable.isColor)

    if batch
      return ['updated', previousVariable]
    else
      @emitChangeEvent(@updateDependencies(updated: [previousVariable]))

  createVariable: (variable, batch) ->
    @variableNames.push(variable.name)
    @variables.push variable

    @variablesByPath[variable.path] ?= []
    @variablesByPath[variable.path].push(variable)

    @evaluateVariableColor(variable)
    @buildDependencyGraph(variable)

    if batch
      return ['created', variable]
    else
      @emitChangeEvent(@updateDependencies(created: [variable]))

  evaluateVariableColor: (variable, wasColor=false) ->
    context = @getContext()
    color = context.readColor(variable.value, true)

    if color?
      return false if wasColor and color.isEqual(variable.color)

      variable.color = color
      variable.isColor = true

      @colorVariables.push(variable) unless variable in @colorVariables
      return true

    else if wasColor
      delete variable.color
      variable.isColor = false
      @colorVariables = @colorVariables.filter (v) -> v isnt variable
      return true

  getVariableStatus: (variable) ->
    return ['created', variable] unless @variablesByPath[variable.path]?

    for v in @variablesByPath[variable.path]
      sameName = v.name is variable.name
      sameValue = v.value is variable.value
      sameRange = if v.bufferRange? and variable.bufferRange?
        v.bufferRange.isEqual(variable.bufferRange)
      else
        v.range[0] is variable.range[0] and v.range[1] is variable.range[1]

      if sameName and sameValue
        if sameRange
          return ['unchanged', v]
        else
          return ['moved', v]
      else if sameName
        return ['updated', v]

    return ['created', variable]

  buildDependencyGraph: (variable) ->
    dependencies = @getVariableDependencies(variable)
    for dependency in dependencies
      a = @dependencyGraph[dependency] ?= []
      a.push(variable.name) unless variable.name in a

  getVariableDependencies: (variable) ->
    dependencies = []
    dependencies.push(variable.value) if variable.value in @variableNames

    if variable.color?.variables.length > 0
      variables = variable.color.variables

      for v in variables
        dependencies.push(v) unless v in dependencies

    dependencies

  collectVariablesByName: (names) ->
    variables = []
    variables.push v for v in @variables when v.name in names
    variables

  updateDependencies: ({created, updated, destroyed}) ->
    variables = []
    dirtyVariableNames = []

    if created?
      variables = variables.concat(created)
      createdVariableNames = created.map (v) -> v.name
    else
      createdVariableNames = []

    variables = variables.concat(updated) if updated?
    variables = variables.concat(destroyed) if destroyed?

    for variable in variables
      if dependencies = @dependencyGraph[variable.name]
        for name in dependencies
          if name not in dirtyVariableNames and name not in createdVariableNames
            dirtyVariableNames.push(name)

    dirtyVariables = @collectVariablesByName(dirtyVariableNames)

    for variable in dirtyVariables
      if @evaluateVariableColor(variable, variable.isColor)
        updated ?= []
        updated.push(variable)

    {created, destroyed, updated}

  emitChangeEvent: ({created, destroyed, updated}) ->
    if created?.length or destroyed?.length or updated?.length
      @emitter.emit 'did-change', {created, destroyed, updated}