removeTrailingUndefs = share.helpers.removeTrailingUndefs
extend = $.extend

share.i18nCollectionTransform = (doc, collection) ->
  for route in collection._disabledOnRoutes
    if route.test(window.location.pathname)
      return doc

  collection_base_language = collection._base_language
  language = TAPi18n.getLanguage()

  if not language? or not doc.i18n?
    delete doc.i18n

    return doc

  dialect_of = share.helpers.dialectOf language

  doc = _.extend({}, doc) # protect original object
  if dialect_of? and doc.i18n[dialect_of]?
    if language != collection_base_language
      extend(true, doc, doc.i18n[dialect_of])
    else
      # if the collection's base language is the dialect that is used as the
      # current language
      doc = extend(true, {}, doc.i18n[dialect_of], doc)

  if doc.i18n[language]?
    extend(true, doc, doc.i18n[language])

  delete doc.i18n

  return doc

share.i18nCollectionExtensions = (obj) ->
  original =
    find: obj.find
    findOne: obj.findOne

  local_session = new ReactiveDict()
  for method of original
    do (method) ->
      obj[method] = (selector, options) ->
        local_session.get("force_lang_switch_reactivity_hook")

        return original[method].apply(obj, removeTrailingUndefs [selector, options])

  obj.forceLangSwitchReactivity = _.once ->
    Deps.autorun () ->
      local_session.set "force_lang_switch_reactivity_hook", TAPi18n.getLanguage()

    return

  obj._disabledOnRoutes = []
  obj._disableTransformationOnRoute = (route) ->
    obj._disabledOnRoutes.push(route)

  if Package.autopublish?
    obj.forceLangSwitchReactivity()

  return obj

toArray = (as) ->
  args = new Array(as.length)
  for i in [0...as.length]
    args[i] = as[i]
  args

TAPi18n.subscribe = (name) ->
  args = toArray arguments
  args.unshift null
  TAPi18n.subscribeWithConnection.apply @, args

TAPi18n.subscribeWithConnection = (connection, name) ->
  args = toArray arguments
  args.splice 1, 0, null
  TAPi18n.subscribeWithConnectionCached.apply @, args

TAPi18n.caches = {}

TAPi18n.subscribeWithConnectionCached = (connection, cacheId, name) ->
# TAPi18n.subscribe = ->
  local_session = new ReactiveDict
  local_session.set("ready", false)
  connection ?= Meteor

  # if typeof arguments[0] is 'string'
  #   name = arguments[0]
  #   shift = 1
  # else
  #   connection = arguments[0] ? Meteor
  #   name = arguments[1]
  #   shift = 2

  # parse arguments
  # params = Array.prototype.slice.call(arguments, shift)
  params = Array.prototype.slice.call(arguments, 3)
  callbacks = {}
  if params.length
    lastParam = params[params.length - 1]
    if (typeof lastParam == "function")
      callbacks.onReady = params.pop()
    else if (lastParam and (typeof lastParam.onReady == "function" or
                             typeof lastParam.onError == "function"))
      callbacks = params.pop()

  # We want the onReady/onError methods to be called only once (not for every language change)
  onReadyCalled = false
  onErrorCalled = false
  original_onReady = callbacks.onReady
  callbacks.onReady = ->
    if onErrorCalled
      return

    local_session.set("ready", true)

    if original_onReady?
      original_onReady()

  if callbacks.onError?
    callbacks.onError = ->
      if onReadyCalled
        _.once callbacks.onError

  subscription = null
  subscription_computation = null
  subscribe = ->
    if cacheId
      hash = name+'-'+cacheId
      man = TAPi18n.caches[hash]
      unless man?
        Tracker.nonreactive ->
          man = new SubsManager subscribe: _.bind connection.subscribe, connection
          TAPi18n.caches[hash] = man

          Tracker.autorun =>
            lang = TAPi18n.getLanguage()
            # console.log ['search lang clear']
            man.clear()

    # subscription_computation, depends on TAPi18n.getLanguage(), to
    # resubscribe once the language gets changed.
    subscription_computation = Deps.autorun () ->
      lang_tag = TAPi18n.getLanguage()

      subargs = removeTrailingUndefs [].concat(name, params, lang_tag, callbacks)
      if cacheId
        # console.log [man, subargs]
        subscription = man.subscribe.apply man, subargs
        subscription.manager = man
      else
        subscription = connection.subscribe.apply connection, subargs

      # if the subscription is already ready:
      local_session.set("ready", subscription?.ready())

  # If TAPi18n is called in a computation, to maintain Meteor.subscribe
  # behavior (which never gets invalidated), we don't want the computation to
  # get invalidated when TAPi18n.getLanguage get invalidated (when language get
  # changed).
  current_computation = Deps.currentComputation
  if currentComputation?
    # If TAPi18n.subscribe was called in a computation, call subscribe in a
    # non-reactive context, but make sure that if the computation is getting
    # invalidated also the subscription computation
    # (invalidations are allowed up->bottom but not bottom->up)
    Deps.onInvalidate ->
      subscription_computation.invalidate()

    Deps.nonreactive () ->
      subscribe()
  else
    # If there is no computation
    subscribe()

  return {
    ready: () ->
      local_session.get("ready")
    stop: () ->
      subscription_computation.stop()
    _getSubscription: -> subscription
  }
