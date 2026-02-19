(function () {
   const MOD_CALL = 'stonehearth_performance_mod:call_handler';

   App.StonehearthPerfModSettingsView = App.View.extend({
      templateName: 'stonehearthPerfModSettings',

      didInsertElement: function () {
         this._super();
         this._load();
      },

      actions: {
         saveSettings: function () {
            const payload = {
               profile: this.$('#perfmodProfile').val(),
               instrumentation_enabled: this.$('#perfmodInstrumentation').is(':checked'),
               discovery_enabled: this.$('#perfmodDiscovery').is(':checked'),
               long_ticks_only: this.$('#perfmodLongTicks').is(':checked')
            };

            radiant.call(MOD_CALL + '.update_settings', payload)
               .done((response) => {
                  this.set('settings', response.settings || payload);
               });
         }
      },

      _load: function () {
         radiant.call(MOD_CALL + '.get_settings')
            .done((settings) => {
               this.set('settings', settings);
               this.$('#perfmodProfile').val(settings.profile || 'SAFE');
               this.$('#perfmodInstrumentation').prop('checked', !!settings.instrumentation_enabled);
               this.$('#perfmodDiscovery').prop('checked', !!settings.discovery_enabled);
               this.$('#perfmodLongTicks').prop('checked', settings.long_ticks_only !== false);
            });
      }
   });
})();
