ModalView = require 'views/core/ModalView'
CreateAccountModal = require 'views/core/CreateAccountModal'
template = require 'templates/play/level/modal/hero-victory-modal'
Achievement = require 'models/Achievement'
EarnedAchievement = require 'models/EarnedAchievement'
CocoCollection = require 'collections/CocoCollection'
LocalMongo = require 'lib/LocalMongo'
utils = require 'core/utils'
ThangType = require 'models/ThangType'
LadderSubmissionView = require 'views/play/common/LadderSubmissionView'
AudioPlayer = require 'lib/AudioPlayer'
User = require 'models/User'
utils = require 'core/utils'
Course = require 'models/Course'
Level = require 'models/Level'
LevelFeedback = require 'models/LevelFeedback'
storage = require 'core/storage'

module.exports = class HeroVictoryModal extends ModalView
  id: 'hero-victory-modal'
  template: template
  closeButton: false
  closesOnClickOutside: false

  subscriptions:
    'ladder:game-submitted': 'onGameSubmitted'

  events:
    'click #continue-button': 'onClickContinue'
    'click .leaderboard-button': 'onClickLeaderboard'
    'click .return-to-course-button': 'onClickReturnToCourse'
    'click .return-to-ladder-button': 'onClickReturnToLadder'
    'click .sign-up-button': 'onClickSignupButton'
    'click .continue-from-offer-button': 'onClickContinueFromOffer'
    'click .skip-offer-button': 'onClickSkipOffer'
    'click #share-level-btn': 'onClickShareLevelButton'

    # Feedback events
    'mouseover .rating i': (e) -> @showStars(@starNum($(e.target)))
    'mouseout .rating i': -> @showStars()
    'click .rating i': (e) ->
      @setStars(@starNum($(e.target)))
      @$el.find('.review, .review-label').show()
    'keypress .review textarea': -> @saveReviewEventually()

  constructor: (options) ->
    super(options)
    @courseID = options.courseID
    @courseInstanceID = options.courseInstanceID

    @session = options.session
    @level = options.level
    @thangTypes = {}
    if @level.isType('hero', 'hero-ladder', 'course', 'course-ladder', 'game-dev', 'web-dev')
      achievements = new CocoCollection([], {
        url: "/db/achievement?related=#{@session.get('level').original}"
        model: Achievement
      })
      @achievements = @supermodel.loadCollection(achievements, 'achievements').model
      @listenToOnce @achievements, 'sync', @onAchievementsLoaded
      @readyToContinue = false
      @waitingToContinueSince = new Date()
      @previousXP = me.get 'points', true
      @previousLevel = me.level()
    else
      @readyToContinue = true
    @playSound 'victory'
    if @level.isType('course', 'game-dev', 'web-dev')
      if nextLevel = @level.get('nextLevel')
        @nextLevel = new Level().setURL "/db/level/#{nextLevel.original}/version/#{nextLevel.majorVersion}"
        @nextLevel = @supermodel.loadModel(@nextLevel).model
      if @courseID
        @course = new Course().setURL "/db/course/#{@courseID}"
        @course = @supermodel.loadModel(@course).model
    if @level.isType('course', 'course-ladder')
      @saveReviewEventually = _.debounce(@saveReviewEventually, 2000)
      @loadExistingFeedback()

    if @level.get('shareable') is 'project'
      @shareURL = "#{window.location.origin}/play/#{@level.get('type')}-level/#{@level.get('slug')}/#{@session.id}"

  destroy: ->
    clearInterval @sequentialAnimationInterval
    @saveReview() if @$el.find('.review textarea').val()
    @feedback?.off()
    super()

  onHidden: ->
    Backbone.Mediator.publish 'music-player:exit-menu', {}
    super()

  loadExistingFeedback: ->
    url = "/db/level/#{@level.id}/feedback"
    @feedback = new LevelFeedback()
    @feedback.setURL url
    @feedback.fetch cache: false
    @listenToOnce(@feedback, 'sync', -> @onFeedbackLoaded())
    @listenToOnce(@feedback, 'error', -> @onFeedbackNotFound())

  onFeedbackLoaded: ->
    @feedback.url = -> '/db/level.feedback/' + @id
    @$el.find('.review textarea').val(@feedback.get('review'))
    @$el.find('.review, .review-label').show()
    @showStars()

  onFeedbackNotFound: ->
    @feedback = new LevelFeedback()
    @feedback.set('levelID', @level.get('slug') or @level.id)
    @feedback.set('levelName', @level.get('name') or '')
    @feedback.set('level', {majorVersion: @level.get('version').major, original: @level.get('original')})
    @showStars()

  onAchievementsLoaded: ->
    @achievements.models = _.filter @achievements.models, (m) -> not m.get('query')?.ladderAchievementDifficulty  # Don't show higher AI difficulty achievements
    @$el.toggleClass 'full-achievements', @achievements.models.length is 3
    thangTypeOriginals = []
    achievementIDs = []
    for achievement in @achievements.models
      rewards = achievement.get('rewards') or {}
      thangTypeOriginals.push rewards.heroes or []
      thangTypeOriginals.push rewards.items or []
      achievement.completed = LocalMongo.matchesQuery(@session.attributes, achievement.get('query'))
      achievementIDs.push(achievement.id) if achievement.completed

    thangTypeOriginals = _.uniq _.flatten thangTypeOriginals
    for thangTypeOriginal in thangTypeOriginals
      thangType = new ThangType()
      thangType.url = "/db/thang.type/#{thangTypeOriginal}/version"
      #thangType.project = ['original', 'rasterIcon', 'name', 'soundTriggers', 'i18n']  # This is what we need, but the PlayHeroesModal needs more, and so we load more to fill up the supermodel.
      thangType.project = ['original', 'rasterIcon', 'name', 'slug', 'soundTriggers', 'featureImages', 'gems', 'heroClass', 'description', 'components', 'extendedName', 'unlockLevelName', 'i18n']
      @thangTypes[thangTypeOriginal] = @supermodel.loadModel(thangType).model

    @newEarnedAchievements = []
    hadOneCompleted = false
    for achievement in @achievements.models
      continue unless achievement.completed
      hadOneCompleted = true
      ea = new EarnedAchievement({
        collection: achievement.get('collection')
        triggeredBy: @session.id
        achievement: achievement.id
      })
      ea.save()
      @newEarnedAchievements.push ea
      @listenToOnce ea, 'sync', ->
        if _.all((ea.id for ea in @newEarnedAchievements))
          @newEarnedAchievementsResource.markLoaded()
          @listenToOnce me, 'sync', ->
            @readyToContinue = true
            @updateSavingProgressStatus()
          me.fetch cache: false unless me.loading

    @readyToContinue = true unless hadOneCompleted

    # have to use a something resource because addModelResource doesn't handle models being upserted/fetched via POST like we're doing here
    @newEarnedAchievementsResource = @supermodel.addSomethingResource('earned achievements') if @newEarnedAchievements.length

  getRenderData: ->
    c = super()
    c.levelName = utils.i18n @level.attributes, 'name'
    if @level.isType('hero', 'game-dev', 'web-dev')
      c.victoryText = utils.i18n @level.get('victory') ? {}, 'body'
    earnedAchievementMap = _.indexBy(@newEarnedAchievements or [], (ea) -> ea.get('achievement'))
    for achievement in (@achievements?.models or [])
      earnedAchievement = earnedAchievementMap[achievement.id]
      if earnedAchievement
        achievement.completedAWhileAgo = new Date().getTime() - Date.parse(earnedAchievement.attributes.changed) > 30 * 1000
      achievement.worth = achievement.get 'worth', true
      achievement.gems = achievement.get('rewards')?.gems
    c.achievements = @achievements?.models.slice() or []
    for achievement in c.achievements
      achievement.description = utils.i18n achievement.attributes, 'description'
      continue unless @supermodel.finished() and proportionalTo = achievement.get 'proportionalTo'
      # For repeatable achievements, we modify their base worth/gems by their repeatable growth functions.
      achievedAmount = utils.getByPath @session.attributes, proportionalTo
      previousAmount = Math.max(0, achievedAmount - 1)
      func = achievement.getExpFunction()
      achievement.previousWorth = (achievement.get('worth') ? 0) * func previousAmount
      achievement.worth = (achievement.get('worth') ? 0) * func achievedAmount
      rewards = achievement.get 'rewards'
      achievement.gems = rewards?.gems * func achievedAmount if rewards?.gems
      achievement.previousGems = rewards?.gems * func previousAmount if rewards?.gems

    # for testing the three states
    #if c.achievements.length
    #  c.achievements = [c.achievements[0].clone(), c.achievements[0].clone(), c.achievements[0].clone()]
    #for achievement, index in c.achievements
    ##  achievement.completed = index > 0
    ##  achievement.completedAWhileAgo = index > 1
    #  achievement.completed = true
    #  achievement.completedAWhileAgo = false
    #  achievement.attributes.worth = (index + 1) * achievement.get('worth', true)
    #  rewards = achievement.get('rewards') or {}
    #  rewards.gems *= (index + 1)

    c.thangTypes = @thangTypes
    c.me = me
    c.readyToRank = @level.isType('hero-ladder', 'course-ladder') and @session.readyToRank()
    c.level = @level
    c.i18n = utils.i18n

    elapsed = (new Date() - new Date(me.get('dateCreated')))
    if me.get 'hourOfCode'
      # Show the Hour of Code "I'm Done" tracking pixel after they played for 20 minutes
      lastLevelOriginal = if storage.load('should-return-to-game-dev-hoc') then '57e95b8c99d82f5a00b9f298' else '541c9a30c6362edfb0f34479'
      lastLevel = @level.get('original') is lastLevelOriginal # hedge-magic or kithgard-gates
      enough = elapsed >= 20 * 60 * 1000 or lastLevel
      tooMuch = elapsed > 120 * 60 * 1000
      showDone = (elapsed >= 30 * 60 * 1000 and not tooMuch) or lastLevel
      if enough and not tooMuch and not me.get('hourOfCodeComplete')
        $('body').append($('<img src="http://code.org/api/hour/finish_codecombat.png" style="visibility: hidden;">'))  # TODO: double-check this when we get our proper pixels, differentiate by game-dev-hoc activity
        me.set 'hourOfCodeComplete', true
        me.patch()
        window.tracker?.trackEvent 'Hour of Code Finish'
      # Show the "I'm done" button between 30 - 120 minutes if they definitely came from Hour of Code
      c.showHourOfCodeDoneButton = showDone

    c.showLeaderboard = @level.get('scoreTypes')?.length > 0 and not @level.isType('course')

    c.showReturnToCourse = not c.showLeaderboard and not me.get('anonymous') and @level.isType('course', 'course-ladder')
    c.isCourseLevel = @level.isType('course')
    c.currentCourseName = @course?.get('name')
    c.currentLevelName = @level?.get('name')
    c.nextLevelName = @nextLevel?.get('name')

    return c

  afterRender: ->
    super()
    @$el.toggleClass 'with-achievements', @level.isType('hero', 'hero-ladder', 'game-dev', 'web-dev')
    return unless @supermodel.finished()
    @playSelectionSound hero, true for original, hero of @thangTypes  # Preload them
    @updateSavingProgressStatus()
    @initializeAnimations()
    if @level.isType('hero-ladder', 'course-ladder')
      @ladderSubmissionView = new LadderSubmissionView session: @session, level: @level
      @insertSubView @ladderSubmissionView, @$el.find('.ladder-submission-view')

  initializeAnimations: ->
    return @endSequentialAnimations() unless @level.isType('hero', 'hero-ladder', 'game-dev', 'web-dev')
    @updateXPBars 0
    #playVictorySound = => @playSound 'victory-title-appear'  # TODO: actually add this
    @$el.find('#victory-header').delay(250).queue(->
      $(@).removeClass('out').dequeue()
      #playVictorySound()
    )
    complete = _.once(_.bind(@beginSequentialAnimations, @))
    @animatedPanels = $()
    panels = @$el.find('.achievement-panel')
    for panel in panels
      panel = $(panel)
      continue unless panel.data('animate')
      @animatedPanels = @animatedPanels.add(panel)
      panel.delay(500)  # Waiting for victory header to show up and fall
      panel.queue(->
        $(@).addClass('earned') # animate out the grayscale
        $(@).dequeue()
      )
      panel.delay(500)
      panel.queue(->
        $(@).find('.reward-image-container').addClass('show')
        $(@).dequeue()
      )
      panel.delay(500)
      panel.queue(-> complete())
    @animationComplete = not @animatedPanels.length
    complete() if @animationComplete

  beginSequentialAnimations: ->
    return if @destroyed
    return unless @level.isType('hero', 'hero-ladder', 'game-dev', 'web-dev')
    @sequentialAnimatedPanels = _.map(@animatedPanels.find('.reward-panel'), (panel) -> {
      number: $(panel).data('number')
      previousNumber: $(panel).data('previous-number')
      textEl: $(panel).find('.reward-text')
      rootEl: $(panel)
      unit: $(panel).data('number-unit')
      hero: $(panel).data('hero-thang-type')
      item: $(panel).data('item-thang-type')
    })

    @totalXP = 0
    @totalXP += panel.number for panel in @sequentialAnimatedPanels when panel.unit is 'xp'
    @totalGems = 0
    @totalGems += panel.number for panel in @sequentialAnimatedPanels when panel.unit is 'gem'
    @gemEl = $('#gem-total')
    @XPEl = $('#xp-total')
    @totalXPAnimated = @totalGemsAnimated = @lastTotalXP = @lastTotalGems = 0
    @sequentialAnimationStart = new Date()
    @sequentialAnimationInterval = setInterval(@tickSequentialAnimation, 1000 / 60)

  tickSequentialAnimation: =>
    # TODO: make sure the animation pulses happen when the numbers go up and sounds play (up to a max speed)
    return @endSequentialAnimations() unless panel = @sequentialAnimatedPanels[0]
    if panel.number
      duration = Math.log(panel.number + 1) / Math.LN10 * 1000  # Math.log10 is ES6
    else
      duration = 1000
    ratio = @getEaseRatio (new Date() - @sequentialAnimationStart), duration
    if panel.unit is 'xp'
      newXP = Math.floor(ratio * (panel.number - panel.previousNumber))
      totalXP = @totalXPAnimated + newXP
      if totalXP isnt @lastTotalXP
        panel.textEl.text('+' + newXP)
        @XPEl.text(totalXP)
        @updateXPBars(totalXP)
        xpTrigger = 'xp-' + (totalXP % 6)  # 6 xp sounds
        @playSound xpTrigger, (0.5 + ratio / 2)
        @XPEl.addClass 'four-digits' if totalXP >= 1000 and @lastTotalXP < 1000
        @XPEl.addClass 'five-digits' if totalXP >= 10000 and @lastTotalXP < 10000
        @lastTotalXP = totalXP
    else if panel.unit is 'gem'
      newGems = Math.floor(ratio * (panel.number - panel.previousNumber))
      totalGems = @totalGemsAnimated + newGems
      if totalGems isnt @lastTotalGems
        panel.textEl.text('+' + newGems)
        @gemEl.text(totalGems)
        gemTrigger = 'gem-' + (parseInt(panel.number * ratio) % 4)  # 4 gem sounds
        @playSound gemTrigger, (0.5 + ratio / 2)
        @gemEl.addClass 'four-digits' if totalGems >= 1000 and @lastTotalGems < 1000
        @gemEl.addClass 'five-digits' if totalGems >= 10000 and @lastTotalGems < 10000
        @lastTotalGems = totalGems
    else if panel.item
      thangType = @thangTypes[panel.item]
      panel.textEl.text utils.i18n(thangType.attributes, 'name')
      @playSound 'item-unlocked' if 0.5 < ratio < 0.6
    else if panel.hero
      thangType = @thangTypes[panel.hero]
      panel.textEl.text utils.i18n(thangType.attributes, 'name')
      @playSelectionSound thangType if 0.5 < ratio < 0.6
    if ratio is 1
      panel.rootEl.removeClass('animating').find('.reward-image-container img').removeClass('pulse')
      @sequentialAnimationStart = new Date()
      if panel.unit is 'xp'
        @totalXPAnimated += panel.number - panel.previousNumber
      else if panel.unit is 'gem'
        @totalGemsAnimated += panel.number - panel.previousNumber
      @sequentialAnimatedPanels.shift()
      return
    panel.rootEl.addClass('animating').find('.reward-image-container').removeClass('pending-reward-image').find('img').addClass('pulse')

  getEaseRatio: (timeSinceStart, duration) ->
    # Ease in/out quadratic - http://gizma.com/easing/
    timeSinceStart = Math.min timeSinceStart, duration
    t = 2 * timeSinceStart / duration
    if t < 1
      return 0.5 * t * t
    --t
    -0.5 * (t * (t - 2) - 1)

  updateXPBars: (achievedXP) ->
    previousXP = @previousXP
    previousXP = previousXP + 1000000 if me.isInGodMode()
    previousLevel = @previousLevel

    currentXP = previousXP + achievedXP
    currentLevel = User.levelFromExp currentXP
    currentLevelXP = User.expForLevel currentLevel

    nextLevel = currentLevel + 1
    nextLevelXP = User.expForLevel nextLevel

    leveledUp = currentLevel > previousLevel
    totalXPNeeded = nextLevelXP - currentLevelXP
    alreadyAchievedPercentage = 100 * (previousXP - currentLevelXP) / totalXPNeeded
    alreadyAchievedPercentage = 0 if alreadyAchievedPercentage < 0  # In case of level up
    if leveledUp
      newlyAchievedPercentage = 100 * (currentXP - currentLevelXP) / totalXPNeeded
    else
      newlyAchievedPercentage = 100 * achievedXP / totalXPNeeded

    xpEl = $('#xp-wrapper')
    xpBarJustEarned = xpEl.find('.xp-bar-already-achieved').css('width', alreadyAchievedPercentage + '%')
    xpBarTotal = xpEl.find('.xp-bar-total').css('width', (alreadyAchievedPercentage + newlyAchievedPercentage) + '%')
    levelLabel = xpEl.find('.level')
    utils.replaceText levelLabel, currentLevel

    if leveledUp and (not @displayedLevel or currentLevel > @displayedLevel)
      @playSound 'level-up'
    @displayedLevel = currentLevel

  endSequentialAnimations: ->
    clearInterval @sequentialAnimationInterval
    @animationComplete = true
    @updateSavingProgressStatus()
    Backbone.Mediator.publish 'music-player:enter-menu', terrain: @level.get('terrain', true) or 'forest'

  updateSavingProgressStatus: ->
    @$el.find('#saving-progress-label').toggleClass('hide', @readyToContinue)
    @$el.find('.next-level-button').toggleClass('hide', not @readyToContinue)
    @$el.find('.sign-up-poke').toggleClass('hide', not @readyToContinue)

  onGameSubmitted: (e) ->
    @returnToLadder()

  returnToLadder: ->
    # Preserve the supermodel as we navigate back to the ladder.
    viewArgs = [{supermodel: if @options.hasReceivedMemoryWarning then null else @supermodel}, @level.get('slug')]
    ladderURL = "/play/ladder/#{@level.get('slug') || @level.id}"
    if leagueID = (@courseInstanceID or @getQueryVariable 'league')
      leagueType = if @level.isType('course-ladder') then 'course' else 'clan'
      viewArgs.push leagueType
      viewArgs.push leagueID
      ladderURL += "/#{leagueType}/#{leagueID}"
    ladderURL += '#my-matches'
    Backbone.Mediator.publish 'router:navigate', route: ladderURL, viewClass: 'views/ladder/LadderView', viewArgs: viewArgs

  playSelectionSound: (hero, preload=false) ->
    return unless sounds = hero.get('soundTriggers')?.selected
    return unless sound = sounds[Math.floor Math.random() * sounds.length]
    name = AudioPlayer.nameForSoundReference sound
    if preload
      AudioPlayer.preloadSoundReference sound
    else
      AudioPlayer.playSound name, 1

  getNextLevelCampaign: ->
    # Much easier to just keep this updated than to dynamically figure it out.
    # TODO: only go back to world selector if any beta campaigns are incomplete
    campaign = {
      'kithgard-gates': '',
      'kithgard-mastery': '',
      'tabula-rasa': '',
      'wanted-poster': '',
      'siege-of-stonehold': '',
      'go-fetch': '',
      'palimpsest': '',
      'quizlet': '',
      'clash-of-clones': 'mountain',
      'summits-gate': 'glacier'
    }[@level.get('slug')] ? @level.get 'campaign'
    # Return to game-dev-hoc instead if we're in that mode, since the levels don't realize they can be in that copycat campaign
    campaign = 'game-dev-hoc' if (campaign is 'dungeon' or @level.get('slug') in ['kithgard-gates', 'hedge-magic']) and storage.load('should-return-to-game-dev-hoc')
    campaign

  getNextLevelLink: (returnToCourse=false) ->
    if @level.isType('course', 'game-dev', 'web-dev') and nextLevel = @level.get('nextLevel') and not returnToCourse
      # need to do something more complicated to load its slug
      console.log 'have @nextLevel', @nextLevel, 'from nextLevel', nextLevel
      link = "/play/level/#{@nextLevel.get('slug')}"
      if @courseID
        link += "?course=#{@courseID}"
        link += "&course-instance=#{@courseInstanceID}" if @courseInstanceID
    else if @level.isType('course')
      link = "/students"
      if @courseID
        link += "/#{@courseID}"
        link += "/#{@courseInstanceID}" if @courseInstanceID
    else
      link = '/play'
      nextCampaign = @getNextLevelCampaign()
      link += '/' + nextCampaign
    link

  onClickContinue: (e, extraOptions=null) ->
    @playSound 'menu-button-click'
    nextLevelLink = @getNextLevelLink extraOptions?.returnToCourse
    # Preserve the supermodel as we navigate back to the world map.
    options =
      justBeatLevel: @level
      supermodel: if @options.hasReceivedMemoryWarning then null else @supermodel
    _.merge options, extraOptions if extraOptions
    if @level.isType('course') and @nextLevel and not options.returnToCourse
      viewClass = require 'views/play/level/PlayLevelView'
      options.courseID = @courseID
      options.courseInstanceID = @courseInstanceID
      viewArgs = [options, @nextLevel.get('slug')]
    else if @level.isType('course')
      # TODO: shouldn't set viewClass and route in different places
      viewClass = require 'views/courses/CoursesView'
      viewArgs = [options]
      if @courseID
        viewClass = require 'views/courses/CourseDetailsView'
        viewArgs.push @courseID
        viewArgs.push @courseInstanceID if @courseInstanceID
    else if @level.isType('course-ladder')
      leagueID = @courseInstanceID or @getQueryVariable 'league'
      nextLevelLink = "/play/ladder/#{@level.get('slug')}"
      nextLevelLink += "/course/#{leagueID}" if leagueID
      viewClass = 'views/ladder/LadderView'
      viewArgs = [options, @level.get('slug')]
      viewArgs = viewArgs.concat ['course', leagueID] if leagueID
    else
      viewClass = require 'views/play/CampaignView'
      viewArgs = [options, @getNextLevelCampaign()]
    navigationEvent = route: nextLevelLink, viewClass: viewClass, viewArgs: viewArgs
    if @level.get('slug') is 'lost-viking' and not (me.get('age') in ['0-13', '14-17'])
      @showOffer navigationEvent
    else
      Backbone.Mediator.publish 'router:navigate', navigationEvent

  onClickLeaderboard: (e) ->
    @onClickContinue e, showLeaderboard: true

  onClickReturnToCourse: (e) ->
    @onClickContinue e, returnToCourse: true

  onClickReturnToLadder: (e) ->
    @playSound 'menu-button-click'
    e.preventDefault()
    @returnToLadder()

  onClickSignupButton: (e) ->
    e.preventDefault()
    window.tracker?.trackEvent 'Started Signup', category: 'Play Level', label: 'Hero Victory Modal', level: @level.get('slug')
    @openModalView new CreateAccountModal()

  showOffer: (@navigationEventUponCompletion) ->
    @$el.find('.modal-footer > *').hide()
    @$el.find(".modal-footer > .offer.#{@level.get('slug')}").show()

  onClickContinueFromOffer: (e) ->
    url = {
      'lost-viking': 'http://www.vikingcodeschool.com/codecombat?utm_source=codecombat&utm_medium=viking_level&utm_campaign=affiliate&ref=Code+Combat+Elite'
    }[@level.get('slug')]
    Backbone.Mediator.publish 'router:navigate', @navigationEventUponCompletion
    window.open url, '_blank' if url

  onClickSkipOffer: (e) ->
    Backbone.Mediator.publish 'router:navigate', @navigationEventUponCompletion

  onClickShareLevelButton: ->
    @$('#share-level-input').val(@shareURL).select()
    @tryCopy()

  # Ratings and reviews

  starNum: (starEl) -> starEl.prevAll('i').length + 1

  showStars: (num) ->
    @$el.find('.rating').show()
    num ?= @feedback?.get('rating') or 0
    stars = @$el.find('.rating i')
    stars.removeClass('glyphicon-star').addClass('glyphicon-star-empty')
    stars.slice(0, num).removeClass('glyphicon-star-empty').addClass('glyphicon-star')

  setStars: (num) ->
    @feedback.set('rating', num)
    @feedback.save()

  saveReviewEventually: ->
    @saveReview()

  saveReview: ->
    @feedback.set('review', @$el.find('.review textarea').val())
    @feedback.save()
