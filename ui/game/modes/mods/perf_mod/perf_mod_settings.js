(function () {
   const MOD_CALL_GET    = 'stonehearth_performance_mod:get_settings';
   const MOD_CALL_UPDATE = 'stonehearth_performance_mod:update_settings';

   App.StonehearthPerfModSettingsView = App.View.extend({
      templateName: 'stonehearthPerfModSettings',

      didInsertElement: function () {
         this._super();
         this._load();
      },

      actions: {
         saveSettings: function () {
            const payload = {
               profile:                 this.$('#perfmodProfile').val(),
               instrumentation_enabled: this.$('#perfmodInstrumentation').is(':checked')
            };

            radiant.call(MOD_CALL_UPDATE, payload)
               .done((response) => {
                  if (response && response.settings) {
                     this._applyToUI(response.settings);
                  }
               });
         }
      },

      _load: function () {
         radiant.call(MOD_CALL_GET)
            .done((settings) => {
               this._applyToUI(settings);
            });
      },

      _applyToUI: function (settings) {
         if (!settings) { return; }
         this.set('settings', settings);
         this.$('#perfmodProfile').val(settings.profile || 'BALANCED');
         this.$('#perfmodInstrumentation').prop('checked', !!settings.instrumentation_enabled);
      }
   });
})();
