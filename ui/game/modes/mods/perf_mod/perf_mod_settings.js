(function () {
   const MOD_CALL_GET      = 'stonehearth_performance_mod:get_settings';
   const MOD_CALL_UPDATE   = 'stonehearth_performance_mod:update_settings';
   const MOD_CALL_SNAPSHOT = 'stonehearth_performance_mod:get_instrumentation_snapshot';
   const MOD_CALL_DUMP     = 'stonehearth_performance_mod:dump_instrumentation';
   const MOD_CALL_RESET    = 'stonehearth_performance_mod:reset_counters';

   const POLL_INTERVAL_MS = 2000;

   App.StonehearthPerfModSettingsView = App.View.extend({
      templateName: 'stonehearthPerfModSettings',

      didInsertElement: function () {
         this._super();
         this._load();
         this._startPolling();

         // Watchdog slider — live display
         var self = this;
         this.$('#perfmodWatchdogThreshold').on('input change', function () {
            var v = parseFloat(this.value);
            self.$('#perfmodWatchdogValue').text(Math.floor(v * 100) + '%');
         });
      },

      willDestroyElement: function () {
         this._stopPolling();
         this._super();
      },

      actions: {
         saveSettings: function () {
            const payload = {
               profile:                 this.$('#perfmodProfile').val(),
               instrumentation_enabled: this.$('#perfmodInstrumentation').is(':checked')
            };

            const self = this;
            radiant.call(MOD_CALL_UPDATE, payload)
               .done(function (response) {
                  if (response && response.settings) {
                     self._applySettings(response.settings);
                  }
                  if (response && response.counters) {
                     self._applyCounters(response.counters);
                  }
               });
         },

         applyPatchToggles: function () {
            const patches = {};
            this.$('.perfmod-patches input[type=checkbox]').each(function () {
               var id = this.getAttribute('data-patch');
               if (id) {
                  patches[id] = this.checked;
               }
            });
            const payload = { patch_enabled: patches };
            const self = this;
            radiant.call(MOD_CALL_UPDATE, payload)
               .done(function (response) {
                  if (response && response.settings) {
                     self._applySettings(response.settings);
                  }
               });
         },

         applyWatchdogThreshold: function () {
            const v = parseFloat(this.$('#perfmodWatchdogThreshold').val());
            if (isNaN(v)) { return; }
            radiant.call(MOD_CALL_UPDATE, { watchdog_idle_threshold: v });
         },

         resetCounters: function () {
            const self = this;
            radiant.call(MOD_CALL_RESET).done(function () {
               self._pollOnce();
            });
         },

         dumpCounters: function () {
            radiant.call(MOD_CALL_DUMP);
         }
      },

      _load: function () {
         const self = this;
         radiant.call(MOD_CALL_GET).done(function (settings) {
            self._applySettings(settings);
         });
         this._pollOnce();
      },

      _startPolling: function () {
         const self = this;
         this._pollHandle = setInterval(function () { self._pollOnce(); }, POLL_INTERVAL_MS);
      },

      _stopPolling: function () {
         if (this._pollHandle) {
            clearInterval(this._pollHandle);
            this._pollHandle = null;
         }
      },

      _pollOnce: function () {
         const self = this;
         radiant.call(MOD_CALL_GET).done(function (settings) {
            self._applySettings(settings);
         });
         radiant.call(MOD_CALL_SNAPSHOT).done(function (snap) {
            self._applyCounters(snap || {});
         });
      },

      _applySettings: function (settings) {
         if (!settings) { return; }
         this.set('settings', settings);

         var appliedStr = (settings.applied_patches || []).join(', ') || '(none)';
         this.set('appliedPatchesStr', appliedStr);

         if (settings.patch_enabled) {
            this.set('patchEnabled', settings.patch_enabled);
         }

         this.$('#perfmodProfile').val(settings.profile || 'BALANCED');
         this.$('#perfmodInstrumentation').prop('checked', !!settings.instrumentation_enabled);

         if (settings.watchdog_threshold != null) {
            this.$('#perfmodWatchdogThreshold').val(settings.watchdog_threshold);
            this.$('#perfmodWatchdogValue').text(Math.floor(settings.watchdog_threshold * 100) + '%');
         }
      },

      _applyCounters: function (snap) {
         // Flatten group-prefixed counter names for Handlebars display
         // Handlebars cannot access keys with colons, so we translate 'PA:reject_hits' -> PA_reject_hits
         var flat = {};
         for (var k in snap) {
            if (snap.hasOwnProperty(k)) {
               flat[k.replace(':', '_')] = snap[k];
            }
         }
         this.set('counters', flat);
      }
   });
})();
