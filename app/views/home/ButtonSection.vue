<template>
  <div>
    <div
      v-if="me.isAnonymous()"
      class="button-section"
    >
      <CTAButton
        :href="`/schools${ educatorSignupExperiment ? '#create-account-teacher' : '' }`"
        @click="homePageEvent(isCodeCombat ? 'Homepage Click Teacher Button #1 CTA' : 'Started Signup')"
      >
        {{ $t('new_home.im_an_educator') }}
      </CTAButton>
      <CTAButton
        href="/parents"
        @click="homePageEvent('Homepage Click Parent Button CTA')"
      >
        {{ $t('new_home.im_a_parent') }}
      </CTAButton>
      <CTAButton
        class="signup-button"
        data-start-on-path="student"
        @click="homePageEvent('Started Signup'); homePageEvent('Homepage Click Student Button CTA')"
      >
        {{ $t('new_home.im_a_student') }}
      </CTAButton>
    </div>
    <div
      v-else
      class="button-section"
    >
      <CTAButton
        v-if="me.isTeacher()"
        href="/teachers/classes"
        target=""
        @click="homePageEvent('Homepage Click My Classes CTA')"
      >
        {{ $t('new_home.goto_classes') }}
      </CTAButton>
      <CTAButton
        v-if="me.isTeacher()"
        href="/teachers/quote"
        @click="homePageEvent('Homepage Click Request A Quote CTA')"
      >
        {{ $t('new_home.request_quote') }}
      </CTAButton>
      <CTAButton
        v-else-if="me.isStudent()"
        href="/students"
        target=""
        @click="homePageEvent('Homepage Click My Courses CTA')"
      >
        {{ $t('new_home.go_to_courses') }}
      </CTAButton>
      <CTAButton
        v-else
        href="/play"
        target=""
        @click="homePageEvent('Homepage Click Continue Playing CTA')"
      >
        {{ $t('courses.continue_playing') }}
      </CTAButton>
    </div>
  </div>
</template>

<script>
import CTAButton from '../../components/common/buttons/CTAButton'
import utils from 'core/utils'

export default {
  name: 'ButtonSection',
  components: {
    CTAButton
  },
  data () {
    return {
      modal: null
    }
  },
  computed: {
    utils () {
      return utils
    },
    me () {
      return me
    },
    educatorSignupExperiment () {
      const value = me.getEducatorSignupExperimentValue()
      return value === 'beta'
    },
  },
  beforeDestroy () {
    if (this.modal) {
      this.modal.remove()
    }
  },
  methods: {
    homePageEvent (action) {
      action = action || 'unknown'
      const properties = {
        category: utils.isCodeCombat ? 'Homepage' : 'Home',
        user: me.get('role') || (me.isAnonymous() && 'anonymous') || 'homeuser'
      }
      return (window.tracker != null ? window.tracker.trackEvent(action, properties) : undefined)
    }
  }
}

</script>

<style scoped lang="scss">
@import 'app/styles/component_variables.scss';

.button-section {
  display: flex;
  justify-content: center;
  flex-wrap: wrap;
  gap: 12px;
  margin-top: 40px;
  margin-bottom: 40px;

  @media screen and (max-height: $small-screen-height) and (orientation: landscape) {
    margin-top: 15px;
    margin-bottom: 15px;
  }
}
</style>
