Level = require 'models/Level'
LevelComponent = require 'models/LevelComponent'
LevelSystem = require 'models/LevelSystem'
Article = require 'models/Article'
LevelSession = require 'models/LevelSession'
CourseInstance = require 'models/CourseInstance'
Classroom = require 'models/Classroom'
{me} = require 'core/auth'
ThangType = require 'models/ThangType'
ThangTypeConstants = require 'lib/ThangTypeConstants'
ThangNamesCollection = require 'collections/ThangNamesCollection'
LZString = require 'lz-string'

CocoClass = require 'core/CocoClass'
AudioPlayer = require 'lib/AudioPlayer'
World = require 'lib/world/world'
utils = require 'core/utils'
loadAetherLanguage = require 'lib/loadAetherLanguage'
aetherUtils = require 'lib/aether_utils'

LOG = false

# This is an initial stab at unifying loading and setup into a single place which can
# monitor everything and keep a LoadingScreen visible overall progress.
#
# Would also like to incorporate into here:
#  * World Building
#  * Sprite map generation
#  * Connecting to Firebase

# LevelLoader depends on SuperModel retrying timed out requests, as these occasionally happen during play.
# If LevelLoader ever moves away from SuperModel, it will have to manage its own retries.

reportedLoadErrorAlready = false

module.exports = class LevelLoader extends CocoClass

  constructor: (options) ->
    @t0 = new Date().getTime()
    super()
    @supermodel = options.supermodel
    @supermodel.setMaxProgress 0.2
    @levelID = options.levelID
    @sessionID = options.sessionID
    @opponentSessionID = options.opponentSessionID
    @tournament = options.tournament ? false
    @team = options.team
    @headless = options.headless
    @loadArticles = options.loadArticles
    @sessionless = options.sessionless
    @fakeSessionConfig = options.fakeSessionConfig
    @spectateMode = options.spectateMode ? false
    @observing = options.observing
    @courseID = options.courseID
    @courseInstanceID = options.courseInstanceID
    @classroomId = options.classroomId
    @thangsOverride = options.thangsOverride

    @worldNecessities = []
    @listenTo @supermodel, 'resource-loaded', @onWorldNecessityLoaded
    @listenTo @supermodel, 'failed', @onWorldNecessityLoadFailed
    @loadLevel()
    @loadAudio()
    @playJingle()
    if @supermodel.finished() and @level.loaded
      @onSupermodelLoaded()
    else
      @loadTimeoutID = setTimeout @reportLoadError.bind(@), 30000
      @listenToOnce @supermodel, 'loaded-all', @onSupermodelLoaded

  # Supermodel (Level) Loading

  loadWorldNecessities: ->
    # TODO: Actually trigger loading, instead of in the constructor
    new Promise((resolve, reject) =>
      return resolve(@) if @world
      @once 'world-necessities-loaded', => resolve(@)
      @once 'world-necessity-load-failed', ({resource}) ->
        { jqxhr } = resource
        reject({message: jqxhr.responseJSON?.message or jqxhr.responseText or 'Unknown Error'})
    )

  loadLevel: ->
    @level = @supermodel.getModel(Level, @levelID) or new Level _id: @levelID
    if @level.loaded
      console.debug 'LevelLoader: level already loaded:', @level if LOG
      @onLevelLoaded()
    else
      console.debug 'LevelLoader: loading level:', @level if LOG
      @level = @supermodel.loadModel(@level, 'level', { data: { cacheEdge: true } }).model
      @listenToOnce @level, 'sync', @onLevelLoaded


  loadClassroomIfNecessary: ->
    if @headless and not @level?.isType('web-dev')
      @onAccessibleLevelLoaded()
      return

    if not @classroomId and not @courseInstanceID
      isAILeague = @tournament or @team or @spectateMode or utils.getQueryVariable 'league'
      if !me.isStudent() or isAILeague
        @onAccessibleLevelLoaded()
      else
        noty({
          text: $.i18n.t('courses.no_classrooms_found'),
          type: 'error',
          timeout: 5000,
        })
      return

    if @courseInstanceID and not @classroomId
      @courseInstance = new CourseInstance({_id: @courseInstanceID})
      @supermodel.trackModel(@courseInstance)
      @courseInstance.fetch().then =>
        @classroomId = @courseInstance.get('classroomID')
        @classroomIdLoaded()
    else
      @classroomIdLoaded()

  classroomIdLoaded: ->
    @classroom = new Classroom({_id: @classroomId})
    @supermodel.trackModel(@classroom)
    @classroom.fetch().then =>
      return if @destroyed
      @classroomLoaded()

  classroomLoaded: ->
    locked = @classroom.isStudentOnLockedLevel(me.get('_id'), @courseID, @level.get('original'))
    if locked
      Backbone.Mediator.publish 'level:locked', level: @level
    else 
      @onAccessibleLevelLoaded()

  reportLoadError: ->
    return if @destroyed
    window.tracker?.trackEvent 'LevelLoadError',
      category: 'Error',
      levelSlug: @work?.level?.slug,
      unloaded: JSON.stringify(@supermodel.report().map (m) -> _.result(m.model, 'url'))
  
  onLevelLoaded: ->
    @loadClassroomIfNecessary()

  onAccessibleLevelLoaded: ->
    console.debug 'LevelLoader: loaded level:', @level if LOG
    @level.set('thangs', @thangsOverride) if @thangsOverride
    if not @sessionless and @level.isType('hero', 'hero-ladder', 'hero-coop', 'course')
      @sessionDependenciesRegistered = {}
    if @level.isType('web-dev')
      @headless = true
      if @sessionless
        # When loading a web-dev level in the level editor, pretend it's a normal hero level so we can put down our placeholder Thang.
        # TODO: avoid this whole roundabout Thang-based way of doing web-dev levels
        originalGet = @level.get
        @level.get = ->
          return 'hero' if arguments[0] is 'type'
          return 'web-dev' if arguments[0] is 'realType'
          originalGet.apply @, arguments
    # I think the modification from https://github.com/codecombat/codecombat/commit/09e354177cb5df7e82cc66668f4c9b6d66d1d740#diff-0aef265179ff51db5b47a0f5be07eea7765664222fcbea6780439f50cd374209L105-R105
    # Can go to Ozaria as well
    if (@courseID and not @level.isType('course', 'course-ladder', 'game-dev', 'web-dev', 'ladder')) or window.serverConfig.picoCTF
      # Because we now use original hero levels for both hero and course levels, we fake being a course level in this context.
      originalGet = @level.get
      realType = @level.get('type')
      @level.get = ->
        return 'course' if arguments[0] is 'type'
        return realType if arguments[0] is 'realType'
        originalGet.apply @, arguments
    if window.serverConfig.picoCTF
      @supermodel.addRequestResource(url: '/picoctf/problems', success: (picoCTFProblems) =>
        @level?.picoCTFProblem = _.find picoCTFProblems, pid: @level.get('picoCTFProblem')
      ).load()
    if @sessionless
      null
    else if @fakeSessionConfig?
      @loadFakeSession()
    else
      @loadSession()
    @populateLevel()

  # Session Loading

  loadFakeSession: ->
    initVals =
      level:
        original: @level.get('original')
        majorVersion: @level.get('version').major
      creator: me.id
      state:
        complete: false
        scripts: {}
      permissions: [
        {target: me.id, access: 'owner'}
        {target: 'public', access: 'write'}
      ]
      codeLanguage: @fakeSessionConfig.codeLanguage or me.get('aceConfig')?.language or 'python'
      _id: LevelSession.fakeID
    @session = new LevelSession initVals
    @session.loaded = true
    @fakeSessionConfig.callback? @session, @level

    # TODO: set the team if we need to, for multiplayer
    # TODO: just finish the part where we make the submit button do what is right when we are fake
    # TODO: anything else to make teacher session-less play make sense when we are fake
    # TODO: make sure we are not actually calling extra save/patch/put things throwing warnings because we know we are fake and so we shouldn't try to do that
    for method in ['save', 'patch', 'put']
      @session[method] = -> console.error "We shouldn't be doing a session.#{method}, since it's a fake session."
    @session.fake = true
    @loadDependenciesForSession @session

  loadSession: ->
    league = utils.getQueryVariable 'league'
    if @sessionID
      url = "/db/level.session/#{@sessionID}"
      if @spectateMode
        url += "?interpret=true"
        if league
          url = "/db/spectate/#{league}/level.session/#{@sessionID}"
    else
      url = "/db/level/#{@levelID}/session"
      if @team
        if @level.isType('ladder')
          url += '?team=humans' # only query for humans when type ladder
        else
          url += "?team=#{@team}"
        if @level.isType('course-ladder') and league and not @courseInstanceID
          url += "&courseInstance=#{league}"
        else if utils.isCodeCombat and @courseID
          url += "&course=#{@courseID}"
          if @courseInstanceID
            url += "&courseInstance=#{@courseInstanceID}"
      else if @courseID
        url += "?course=#{@courseID}"
        if @courseInstanceID
          url += "&courseInstance=#{@courseInstanceID}"
        if @classroomId
          url += "&classroom=#{@classroomId}"
      else if codeLanguage = utils.getQueryVariable 'codeLanguage'
        url += "?codeLanguage=#{codeLanguage}" # For non-classroom anonymous users
      if password = utils.getQueryVariable 'password'
        delimiter = if /\?/.test(url) then '&' else '?'
        url += delimiter + 'password=' + password

    if @tournament
      url = "/db/level.session/#{@sessionID}/tournament-snapshot/#{@tournament}"
    session = new LevelSession().setURL url
    if @headless and not @level.isType('web-dev')
      session.project = ['creator', 'team', 'heroConfig', 'codeLanguage', 'submittedCodeLanguage', 'state', 'submittedCode', 'submitted']
    @sessionResource = @supermodel.loadModel(session, 'level_session', {cache: false})
    @session = @sessionResource.model
    if @opponentSessionID
      opponentURL = "/db/level.session/#{@opponentSessionID}?interpret=true"
      if league
        opponentURL = "/db/spectate/#{league}/level.session/#{@opponentSessionID}"
      if @tournament
        opponentURL = "/db/level.session/#{@opponentSessionID}/tournament-snapshot/#{@tournament}" # this url also get interpret
      opponentSession = new LevelSession().setURL opponentURL
      opponentSession.project = session.project if @headless
      @opponentSessionResource = @supermodel.loadModel(opponentSession, 'opponent_session', {cache: false})
      @opponentSession = @opponentSessionResource.model

    if @session.loaded
      console.debug 'LevelLoader: session already loaded:', @session if LOG
      @session.setURL '/db/level.session/' + @session.id
      @preloadTeamForSession @session
    else
      console.debug 'LevelLoader: loading session:', @session if LOG
      @listenToOnce @session, 'sync', ->
        @session.setURL '/db/level.session/' + @session.id
        @preloadTeamForSession @session
    if @opponentSession
      if @opponentSession.loaded
        console.debug 'LevelLoader: opponent session already loaded:', @opponentSession if LOG
        @preloadTokenForOpponentSession @opponentSession
      else
        console.debug 'LevelLoader: loading opponent session:', @opponentSession if LOG
        @listenToOnce @opponentSession, 'sync', @preloadTokenForOpponentSession

  preloadTeamForSession: (session) =>
    if @level.isType('ladder') and @team is 'ogres' and session.get('team') is 'humans'
      session.set 'team', 'ogres'
      unless session.get 'interpret'
        code = session.get('code')
        if _.isEmpty(code)
          code = session.get('submittedCode')
        code['hero-placeholder-1'] = JSON.parse(JSON.stringify(code['hero-placeholder']))
        session.set 'code', code
    @loadDependenciesForSession session

  preloadTokenForOpponentSession: (session) =>
    if @level.isType('ladder') and @team != 'ogres' and session.get('team') is 'humans'
      session.set 'team', 'ogres'
      # since opponentSession always get interpret, so we don't need to copy code

    language = session.get('codeLanguage')
    compressed = session.get 'interpret'
    if language not in ['java', 'cpp'] or not compressed
      @loadDependenciesForSession session
    else
      uncompressed = LZString.decompressFromUTF16 compressed
      code = session.get 'code'

      aetherUtils.fetchToken(uncompressed, language).then((token) =>
        code[if session.get('team') is 'humans' then 'hero-placeholder' else 'hero-placeholder-1'].plan = token
        session.set 'code', code
        session.unset 'interpret'
        @loadDependenciesForSession session
      )

  loadDependenciesForSession: (session) ->
    console.debug "Loading dependencies for session: ", session if LOG
    if me.id isnt session.get('creator') or @spectateMode
      session.patch = session.save = session.put = -> console.error "Not saving session, since we didn't create it."
    else if codeLanguage = utils.getQueryVariable 'codeLanguage'
      session.set 'codeLanguage', codeLanguage
    if me.id is session.get('creator')
      # do not use .set since we won't update fullName to server
      session.fullName = _.filter([me.get('firstName'), me.get('lastName')]).join(' ')
    @worldNecessities = @worldNecessities.concat(@loadCodeLanguagesForSession session)
    if compressed = session.get 'interpret'
      uncompressed = LZString.decompressFromUTF16 compressed
      code = session.get 'code'
      code[if session.get('team') is 'humans' then 'hero-placeholder' else 'hero-placeholder-1'].plan = uncompressed
      session.set 'code', code
      session.unset 'interpret'
    if session.get('codeLanguage') in ['io', 'clojure']
      session.set 'codeLanguage', 'python'
    if session is @session
      @addSessionBrowserInfo session
      # hero-ladder games require the correct session team in level:loaded
      team = @team ? @session.get('team')
      Backbone.Mediator.publish 'level:loaded', level: @level, team: team
      @publishedLevelLoaded = true
      Backbone.Mediator.publish 'level:session-loaded', level: @level, session: @session
      @consolidateFlagHistory() if @opponentSession?.loaded
    else if session is @opponentSession
      @consolidateFlagHistory() if @session.loaded

    if not @level.usesSessionHeroThangType()
      @sessionDependenciesRegistered?[session.id] = true
      if @checkAllWorldNecessitiesRegisteredAndLoaded()
        # Finish if all world necessities were completed by the time the session loaded.
        @onWorldNecessitiesLoaded()
      # Return before loading heroConfig ThangTypes.
      return

    # Load the hero ThangType
    heroThangType = switch
      when utils.isOzaria
        # Use configured Ozaria hero
        me.get('ozariaUserOptions')?.isometricThangTypeOriginal or ThangType.heroes['hero-b']
      when session.get('heroConfig')?.thangType
        # Use the hero set in the session
        session.get('heroConfig').thangType
      when me.get('heroConfig')?.thangType and session is @session and not @headless
        # Use the hero set for the user, if the user is me and it's my level
        me.get('heroConfig').thangType
      when @level.isType('course')
        # Default to Anya in classroom mode
        ThangType.heroes.captain
      else
        # Default to Tharin in home mode
        ThangType.heroes.knight
    if @level.get('product', true) is 'codecombat-junior'
      # If we got into a codecombat-junior level with a codecombat hero, pick an equivalent codecombat-junior hero to use instead
      juniorHeroReplacement = ThangTypeConstants.juniorHeroReplacements[_.invert(ThangTypeConstants.heroes)[heroThangType]]
    else
      # If we got into a codecombat level with a codecombat-junior hero, pick an equivalent codecombat hero to use instead
      juniorHeroReplacement = _.invert(ThangTypeConstants.juniorHeroReplacements)[_.invert(ThangTypeConstants.heroes)[heroThangType]]
    heroThangType = ThangTypeConstants.heroes[juniorHeroReplacement] if juniorHeroReplacement

    url = "/db/thang.type/#{heroThangType}/version"
    if heroResource = @maybeLoadURL(url, ThangType, 'thang')
      console.debug "Pushing hero ThangType resource: ", heroResource if LOG
      @worldNecessities.push heroResource

    if not @level.usesSessionHeroInventory()
      @sessionDependenciesRegistered[session.id] = true
      if @checkAllWorldNecessitiesRegisteredAndLoaded()
        # Finish if all world necessities were completed by the time the session loaded.
        @onWorldNecessitiesLoaded()
      # Return before loading heroConfig.inventory ThangTypes.
      return

    # Load the ThangTypes needed for the session's heroConfig for these types of levels
    heroConfig = _.cloneDeep(session.get('heroConfig'))
    heroConfig ?= _.cloneDeep(me.get('heroConfig')) if session is @session and not @headless
    heroConfig ?= {}
    heroConfig.inventory ?= feet: '53e237bf53457600003e3f05'  # If all else fails, assign simple boots.
    heroConfig.thangType ?= heroThangType
    session.set 'heroConfig', heroConfig unless _.isEqual heroConfig, session.get('heroConfig')
    url = "/db/thang.type/#{heroConfig.thangType}/version"
    if not heroResource
      # We had already loaded it, so move to the next dependencies step now
      heroThangType = @supermodel.getModel url
      @loadDefaultComponentsForThangType heroThangType
      @loadThangsRequiredByThangType heroThangType

    for itemThangType in _.values(heroConfig.inventory)
      url = "/db/thang.type/#{itemThangType}/version?project=name,components,original,rasterIcon,kind"
      if itemResource = @maybeLoadURL(url, ThangType, 'thang')
        @worldNecessities.push itemResource
      else
        itemThangType = @supermodel.getModel url
        @loadDefaultComponentsForThangType itemThangType
        @loadThangsRequiredByThangType itemThangType
    @sessionDependenciesRegistered[session.id] = true
    if _.size(@sessionDependenciesRegistered) is 2 and @checkAllWorldNecessitiesRegisteredAndLoaded()
      @onWorldNecessitiesLoaded()

  loadCodeLanguagesForSession: (session) ->
    codeLanguages = _.uniq _.filter [session.get('codeLanguage') or 'python', session.get('submittedCodeLanguage')]
    resources = []
    for codeLanguage in codeLanguages
      continue if codeLanguage in ['clojure', 'io']
      do (codeLanguage) => # Prevents looped variables from being reassigned when async callbacks happen
        languageModuleResource = @supermodel.addSomethingResource "language_module_#{codeLanguage}"
        resources.push(languageModuleResource)
        loadAetherLanguage(codeLanguage).then (aetherLang) =>
          languageModuleResource.markLoaded()
    return resources

  addSessionBrowserInfo: (session) ->
    return unless me.id is session.get 'creator'
    return unless $.browser?
    return if @spectateMode
    return if session.fake
    browser = {}
    browser['desktop'] = $.browser.desktop if $.browser.desktop
    browser['name'] = $.browser.name if $.browser.name
    browser['platform'] = $.browser.platform if $.browser.platform
    browser['version'] = $.browser.version if $.browser.version
    return if _.isEqual session.get('browser'), browser
    session.set 'browser', browser
    session.save({browser}, {patch: true, type: 'PUT'})

  consolidateFlagHistory: ->
    state = @session.get('state') ? {}
    myFlagHistory = _.filter state.flagHistory ? [], team: @session.get('team')
    opponentFlagHistory = _.filter @opponentSession.get('state')?.flagHistory ? [], team: @opponentSession.get('team')
    state.flagHistory = myFlagHistory.concat opponentFlagHistory
    @session.set 'state', state

  # Grabbing the rest of the required data for the level

  populateLevel: ->
    thangIDs = []
    componentVersions = []
    systemVersions = []
    articleVersions = []

    flagThang = thangType: '53fa25f25bc220000052c2be', id: 'Placeholder Flag', components: []
    for thang in (@level.get('thangs') or []).concat [flagThang]
      thangIDs.push thang.thangType
      @loadThangsRequiredByLevelThang(thang)
      for comp in thang.components or []
        componentVersions.push _.pick(comp, ['original', 'majorVersion'])
    systems = @level.get('systems') or []
    for system in systems
      systemVersions.push _.pick(system, ['original', 'majorVersion'])
      @loadThangsRequiredFromSystemObject(system)
      if indieSprites = system?.config?.indieSprites
        for indieSprite in indieSprites
          thangIDs.push indieSprite.thangType

    unless @headless and not @loadArticles
      for article in @level.get('documentation')?.generalArticles or []
        articleVersions.push _.pick(article, ['original', 'majorVersion'])

    objUniq = (array) -> _.uniq array, false, (arg) -> JSON.stringify(arg)

    worldNecessities = []

    @thangIDs = _.uniq thangIDs
    @thangNames = new ThangNamesCollection(@thangIDs)
    worldNecessities.push @supermodel.loadCollection(@thangNames, 'thang_names')
    @listenToOnce @thangNames, 'sync', @onThangNamesLoaded
    worldNecessities.push @sessionResource if @sessionResource?.isLoading
    worldNecessities.push @opponentSessionResource if @opponentSessionResource?.isLoading

    for obj in objUniq componentVersions
      url = "/db/level.component/#{obj.original}/version/#{obj.majorVersion}"
      worldNecessities.push @maybeLoadURL(url, LevelComponent, 'component')
    for obj in objUniq systemVersions
      url = "/db/level.system/#{obj.original}/version/#{obj.majorVersion}"
      worldNecessities.push(@maybeLoadURL(url, LevelSystem, 'system'))
    for obj in objUniq articleVersions
      url = "/db/article/#{obj.original}/version/#{obj.majorVersion}"
      @maybeLoadURL url, Article, 'article'
    if obj = @level.get 'nextLevel'  # TODO: update to get next level from campaigns, not this old property
      url = "/db/level/#{obj.original}/version/#{obj.majorVersion}"
      @maybeLoadURL url, Level, 'level'

    @worldNecessities = @worldNecessities.concat worldNecessities

  loadThangsRequiredByLevelThang: (levelThang) ->
    @loadThangsRequiredFromComponentList levelThang.components

  loadThangsRequiredByThangType: (thangType) ->
    @loadThangsRequiredFromComponentList thangType.get('components')

  loadThangTypeData: (thangType) ->
    url = "/db/thang.type/#{thangType}/version?project=name,components,original,rasterIcon,kind,prerenderedSpriteSheetData"
    @worldNecessities.push @maybeLoadURL(url, ThangType, 'thang')

  loadThangsRequiredFromComponentList: (components) ->
    return unless components
    requiredThangTypes = []
    for component in components when component.config
      if component.original is LevelComponent.EquipsID
        requiredThangTypes.push itemThangType for itemThangType in _.values (component.config.inventory ? {})
      else if component.config.requiredThangTypes
        requiredThangTypes = requiredThangTypes.concat component.config.requiredThangTypes
    extantRequiredThangTypes = _.filter requiredThangTypes
    if extantRequiredThangTypes.length < requiredThangTypes.length
      console.error "Some Thang had a blank required ThangType in components list:", components
    for thangType in extantRequiredThangTypes
      if thangType + '' is '[object Object]'
        console.error("Some Thang had an improperly stringified required ThangType in components list:", thangType, components) 
      else
        @loadThangTypeData(thangType)

  loadThangsRequiredFromSystemDefaults: (systemModel) ->
    config = systemModel.get('configSchema')
    if not config
      return
    configDefault = config.default
    @loadThangsRequiredFromSystemConfig(configDefault)
  
  loadThangsRequiredFromSystemObject: (system) ->
    if system.config
      @loadThangsRequiredFromSystemConfig(system.config)


  loadThangsRequiredFromSystemConfig: (config) ->
    if not config
      return
    requiredThangTypes = config.requiredThangTypes
    if not requiredThangTypes
      return
    for thangType in requiredThangTypes
      if thangType + '' is '[object Object]'
        console.error("Some System had an improperly stringified required ThangType:", thangType, system.name)
      else
        @loadThangTypeData(thangType)

  onThangNamesLoaded: (thangNames) ->
    for thangType in thangNames.models
      @loadDefaultComponentsForThangType(thangType)
      @loadThangsRequiredByThangType(thangType)
    @thangNamesLoaded = true
    @onWorldNecessitiesLoaded() if @checkAllWorldNecessitiesRegisteredAndLoaded()

  loadDefaultComponentsForThangType: (thangType) ->
    return unless components = thangType.get('components')
    for component in components
      url = "/db/level.component/#{component.original}/version/#{component.majorVersion}"
      @worldNecessities.push @maybeLoadURL(url, LevelComponent, 'component')

  onWorldNecessityLoaded: (resource) ->
    # Note: this can also be called when session, opponentSession, or other resources with dedicated load handlers are loaded, before those handlers
    index = @worldNecessities.indexOf(resource)
    if resource.name is 'system'
      @loadThangsRequiredFromSystemDefaults(resource.model)
      

    if resource.name is 'thang'
      @loadDefaultComponentsForThangType(resource.model)
      @loadThangsRequiredByThangType(resource.model)

    return unless index >= 0
    @worldNecessities.splice(index, 1)
    @worldNecessities = (r for r in @worldNecessities when r?)
    @onWorldNecessitiesLoaded() if @checkAllWorldNecessitiesRegisteredAndLoaded()

  onWorldNecessityLoadFailed: (event) ->
    @reportLoadError()
    @trigger('world-necessity-load-failed', event)

  checkAllWorldNecessitiesRegisteredAndLoaded: ->
    reason = @getReasonForNotYetLoaded()
    console.debug('LevelLoader: Reason not loaded:', reason) if reason and LOG
    return !reason

  getReasonForNotYetLoaded: ->
    return 'worldNecessities still loading' unless _.filter(@worldNecessities).length is 0
    return 'thang names need to load' unless @thangNamesLoaded
    return 'not all session dependencies registered' if @sessionDependenciesRegistered and not @sessionDependenciesRegistered[@session.id] and not @sessionless
    return 'not all opponent session dependencies registered' if @sessionDependenciesRegistered and @opponentSession and not @sessionDependenciesRegistered[@opponentSession.id] and not @sessionless
    return 'session is not loaded' unless @session?.loaded or @sessionless
    return 'opponent session is not loaded' if @opponentSession and (not @opponentSession.loaded or @opponentSession.get('interpret'))
    return 'have not published level loaded' unless @publishedLevelLoaded or @sessionless
    return 'cpp/java token is still fetching' if @opponentSession and @opponentSession.get 'interpret'
    return ''

  onWorldNecessitiesLoaded: ->
    console.debug "World necessities loaded." if LOG
    return if @initialized
    @initialized = true
    @initWorld()
    @supermodel.clearMaxProgress()
    @trigger 'world-necessities-loaded'
    return if @headless
    thangsToLoad = _.uniq( (t.spriteName for t in @world.thangs when t.exists) )
    nameModelTuples = ([thangType.get('name'), thangType] for thangType in @thangNames.models)
    nameModelMap = _.zipObject nameModelTuples
    @spriteSheetsToBuild ?= []

#    for thangTypeName in thangsToLoad
#      thangType = nameModelMap[thangTypeName]
#      continue if not thangType or thangType.isFullyLoaded()
#      thangType.fetch()
#      thangType = @supermodel.loadModel(thangType, 'thang').model
#      res = @supermodel.addSomethingResource 'sprite_sheet', 5
#      res.thangType = thangType
#      res.markLoading()
#      @spriteSheetsToBuild.push res

    @buildLoopInterval = setInterval @buildLoop, 5 if @spriteSheetsToBuild.length

  maybeLoadURL: (url, Model, resourceName) ->
    return if @supermodel.getModel(url)
    model = new Model().setURL url
    @supermodel.loadModel(model, resourceName)

  onSupermodelLoaded: ->
    clearTimeout @loadTimeoutID
    return if @destroyed
    console.debug 'SuperModel for Level loaded in', new Date().getTime() - @t0, 'ms' if LOG
    @loadLevelSounds()
    @denormalizeSession()

  buildLoop: =>
    someLeft = false
    for spriteSheetResource, i in @spriteSheetsToBuild ? []
      continue if spriteSheetResource.spriteSheetKeys
      someLeft = true
      thangType = spriteSheetResource.thangType
      if thangType.loaded and not thangType.loading
        keys = @buildSpriteSheetsForThangType spriteSheetResource.thangType
        if keys and keys.length
          @listenTo spriteSheetResource.thangType, 'build-complete', @onBuildComplete
          spriteSheetResource.spriteSheetKeys = keys
        else
          spriteSheetResource.markLoaded()

    clearInterval @buildLoopInterval unless someLeft

  onBuildComplete: (e) ->
    resource = null
    for resource in @spriteSheetsToBuild
      break if e.thangType is resource.thangType
    return console.error 'Did not find spriteSheetToBuildResource for', e unless resource
    resource.spriteSheetKeys = (k for k in resource.spriteSheetKeys when k isnt e.key)
    resource.markLoaded() if resource.spriteSheetKeys.length is 0

  denormalizeSession: ->
    return if @sessionDenormalized or @spectateMode or @sessionless or me.isSessionless()
    return if @headless and not @level.isType('web-dev')
    # This is a way (the way?) PUT /db/level.sessions/undefined was happening
    # See commit c242317d9
    return if not @session?.id
    patch =
      'levelName': @level.get('name')
      'levelID': @level.get('slug') or @level.id
    if me.id is @session.get 'creator'
      patch.creatorName = me.get('name')
      if currentAge = me.age()
        patch.creatorAge = currentAge
    for key, value of patch
      if @session.get(key) is value
        delete patch[key]
    unless _.isEmpty patch
      if @level.isLadder() and @session.get('team')
        patch.team = @session.get('team')
        if @level.isType('ladder')
          patch.team = 'humans'  # Save the team in case we just assigned it in PlayLevelView, since sometimes that wasn't getting saved and we don't want to save ogres team in ladder
      @session.set key, value for key, value of patch
      tempSession = new LevelSession _id: @session.id
      tempSession.save(patch, {patch: true, type: 'PUT'})
    @sessionDenormalized = true

  # Building sprite sheets

  buildSpriteSheetsForThangType: (thangType) ->
    return if @headless
    # TODO: Finish making sure the supermodel loads the raster image before triggering load complete, and that the cocosprite has access to the asset.
#    if f = thangType.get('raster')
#      queue = new createjs.LoadQueue()
#      queue.loadFile('/file/'+f)
    @grabThangTypeTeams() unless @thangTypeTeams
    keys = []
    for team in @thangTypeTeams[thangType.get('original')] ? [null]
      spriteOptions = {resolutionFactor: SPRITE_RESOLUTION_FACTOR, async: true}
      if thangType.get('kind') is 'Floor'
        spriteOptions.resolutionFactor = 2
      if team and color = @teamConfigs[team]?.color
        spriteOptions.colorConfig = team: color
      key = @buildSpriteSheet thangType, spriteOptions
      if _.isString(key) then keys.push key
    keys

  grabThangTypeTeams: ->
    @grabTeamConfigs()
    @thangTypeTeams = {}
    for thang in @level.get('thangs')
      if @level.isType('hero', 'course') and thang.id is 'Hero Placeholder'
        continue  # No team colors for heroes on single-player levels
      for component in thang.components
        if team = component.config?.team
          @thangTypeTeams[thang.thangType] ?= []
          @thangTypeTeams[thang.thangType].push team unless team in @thangTypeTeams[thang.thangType]
          break
    @thangTypeTeams

  grabTeamConfigs: ->
    for system in @level.get('systems')
      if @teamConfigs = system.config?.teamConfigs
        break
    unless @teamConfigs
      # Hack: pulled from Alliance System code. TODO: put in just one place.
      @teamConfigs = {'humans': {'superteam': 'humans', 'color': {'hue': 0, 'saturation': 0.75, 'lightness': 0.5}, 'playable': true}, 'ogres': {'superteam': 'ogres', 'color': {'hue': 0.66, 'saturation': 0.75, 'lightness': 0.5}, 'playable': false}, 'neutral': {'superteam': 'neutral', 'color': {'hue': 0.33, 'saturation': 0.75, 'lightness': 0.5}}}
    @teamConfigs

  buildSpriteSheet: (thangType, options) ->
    if thangType.get('name') is 'Wizard'
      options.colorConfig = me.get('wizard')?.colorConfig or {}
    thangType.buildSpriteSheet options

  # World init

  initWorld: ->
    return if @level.isType('web-dev')
    @world = new World()
    @world.levelSessionIDs = if @opponentSessionID then [@sessionID, @opponentSessionID] else [@sessionID]
    @world.submissionCount = @session?.get('state')?.submissionCount ? 0
    @world.flagHistory = @session?.get('state')?.flagHistory ? []
    @world.difficulty = @session?.get('state')?.difficulty ? 0
    if @observing
      @world.difficulty = Math.max 0, @world.difficulty - 1  # Show the difficulty they won, not the next one.
    serializedLevel = @level.serialize {@supermodel, @session, @opponentSession, @headless, @sessionless}
    if me.constrainHeroHealth()
      serializedLevel.constrainHeroHealth = true
    @world.loadFromLevel serializedLevel, false
    console.debug 'World has been initialized from level loader.' if LOG

  # Initial Sound Loading

  playJingle: ->
    return if utils.isOzaria # TODO: replace with Ozaria level loading jingles
    return if @headless or not me.get('volume')
    volume = 0.5
    if me.level() < 3
      volume = 0.25  # Start softly, since they may not be expecting it
    # Apparently the jingle, when it tries to play immediately during all this loading, you can't hear it.
    # Add the timeout to fix this weird behavior.
    f = ->
      jingles = ['ident_1', 'ident_2']
      AudioPlayer.playInterfaceSound jingles[Math.floor Math.random() * jingles.length], volume
    setTimeout f, 500

  loadAudio: ->
    return if utils.isOzaria  # TODO: replace with Ozaria sound
    return if @headless or not me.get('volume')
    AudioPlayer.preloadInterfaceSounds ['victory']

  loadLevelSounds: ->
    return if @headless or not me.get('volume')
    scripts = @level.get 'scripts'
    return unless scripts

    for script in scripts when script.noteChain
      for noteGroup in script.noteChain when noteGroup.sprites
        for sprite in noteGroup.sprites when sprite.say?.sound
          AudioPlayer.preloadSoundReference(sprite.say.sound)

    thangTypes = @supermodel.getModels(ThangType)
    for thangType in thangTypes
      for trigger, sounds of thangType.get('soundTriggers') or {} when trigger isnt 'say'
        AudioPlayer.preloadSoundReference sound for sound in sounds

  # everything else sound wise is loaded as needed as worlds are generated

  progress: -> @supermodel.progress

  destroy: ->
    clearInterval @buildLoopInterval if @buildLoopInterval
    super()
