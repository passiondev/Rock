System.register(['vue', '@Obsidian/Controls/notificationBox.obs', '@Obsidian/Controls/panel.obs', '@Obsidian/Controls/rockForm.obs', '@Obsidian/Controls/rockButton.obs', '@Obsidian/Enums/Controls/btnType', '@Obsidian/Enums/Controls/btnSize', '@Obsidian/Controls/auditDetail.obs', '@Obsidian/Controls/modal.obs', '@Obsidian/Controls/attributeValuesContainer.obs', '@Obsidian/Controls/checkBox.obs', '@Obsidian/Controls/textBox.obs', '@Obsidian/Controls/lavaCommandPicker.obs', '@Obsidian/Controls/cacheabilityPicker.obs', '@Obsidian/Controls/radioButtonList.obs', '@Obsidian/Utility/block', '@Obsidian/Utility/component', '@Obsidian/Controls/codeEditor.obs', '@Obsidian/Utility/numberUtils', '@Obsidian/Controls/numberBox.obs', '@Obsidian/Utility/url'], (function (exports) {
  'use strict';
  var createElementVNode, defineComponent, ref, watch, openBlock, createElementBlock, createVNode, unref, isRef, toDisplayString, createCommentVNode, withCtx, createTextVNode, computed, Fragment, createBlock, NotificationBox, Panel, RockForm, RockButton, BtnType, BtnSize, AuditDetail, Modal, AttributeValuesContainer, CheckBox, TextBox, LavaCommandPicker, CacheabilityPicker, RadioButtonList, useInvokeBlockAction, watchPropertyChanges, useConfigurationValues, getSecurityGrant, provideSecurityGrant, propertyRef, updateRefValue, CodeEditor, toNumberOrNull, makeUrlRedirectSafe;
  return {
    setters: [function (module) {
      createElementVNode = module.createElementVNode;
      defineComponent = module.defineComponent;
      ref = module.ref;
      watch = module.watch;
      openBlock = module.openBlock;
      createElementBlock = module.createElementBlock;
      createVNode = module.createVNode;
      unref = module.unref;
      isRef = module.isRef;
      toDisplayString = module.toDisplayString;
      createCommentVNode = module.createCommentVNode;
      withCtx = module.withCtx;
      createTextVNode = module.createTextVNode;
      computed = module.computed;
      Fragment = module.Fragment;
      createBlock = module.createBlock;
    }, function (module) {
      NotificationBox = module["default"];
    }, function (module) {
      Panel = module["default"];
    }, function (module) {
      RockForm = module["default"];
    }, function (module) {
      RockButton = module["default"];
    }, function (module) {
      BtnType = module.BtnType;
    }, function (module) {
      BtnSize = module.BtnSize;
    }, function (module) {
      AuditDetail = module["default"];
    }, function (module) {
      Modal = module["default"];
    }, function (module) {
      AttributeValuesContainer = module["default"];
    }, function (module) {
      CheckBox = module["default"];
    }, function (module) {
      TextBox = module["default"];
    }, function (module) {
      LavaCommandPicker = module["default"];
    }, function (module) {
      CacheabilityPicker = module["default"];
    }, function (module) {
      RadioButtonList = module["default"];
    }, function (module) {
      useInvokeBlockAction = module.useInvokeBlockAction;
      watchPropertyChanges = module.watchPropertyChanges;
      useConfigurationValues = module.useConfigurationValues;
      getSecurityGrant = module.getSecurityGrant;
      provideSecurityGrant = module.provideSecurityGrant;
    }, function (module) {
      propertyRef = module.propertyRef;
      updateRefValue = module.updateRefValue;
    }, function (module) {
      CodeEditor = module["default"];
    }, function (module) {
      toNumberOrNull = module.toNumberOrNull;
    }, function () {}, function (module) {
      makeUrlRedirectSafe = module.makeUrlRedirectSafe;
    }],
    execute: (function () {

      function ownKeys(object, enumerableOnly) {
        var keys = Object.keys(object);
        if (Object.getOwnPropertySymbols) {
          var symbols = Object.getOwnPropertySymbols(object);
          enumerableOnly && (symbols = symbols.filter(function (sym) {
            return Object.getOwnPropertyDescriptor(object, sym).enumerable;
          })), keys.push.apply(keys, symbols);
        }
        return keys;
      }
      function _objectSpread2(target) {
        for (var i = 1; i < arguments.length; i++) {
          var source = null != arguments[i] ? arguments[i] : {};
          i % 2 ? ownKeys(Object(source), !0).forEach(function (key) {
            _defineProperty(target, key, source[key]);
          }) : Object.getOwnPropertyDescriptors ? Object.defineProperties(target, Object.getOwnPropertyDescriptors(source)) : ownKeys(Object(source)).forEach(function (key) {
            Object.defineProperty(target, key, Object.getOwnPropertyDescriptor(source, key));
          });
        }
        return target;
      }
      function asyncGeneratorStep(gen, resolve, reject, _next, _throw, key, arg) {
        try {
          var info = gen[key](arg);
          var value = info.value;
        } catch (error) {
          reject(error);
          return;
        }
        if (info.done) {
          resolve(value);
        } else {
          Promise.resolve(value).then(_next, _throw);
        }
      }
      function _asyncToGenerator(fn) {
        return function () {
          var self = this,
            args = arguments;
          return new Promise(function (resolve, reject) {
            var gen = fn.apply(self, args);
            function _next(value) {
              asyncGeneratorStep(gen, resolve, reject, _next, _throw, "next", value);
            }
            function _throw(err) {
              asyncGeneratorStep(gen, resolve, reject, _next, _throw, "throw", err);
            }
            _next(undefined);
          });
        };
      }
      function _defineProperty(obj, key, value) {
        key = _toPropertyKey(key);
        if (key in obj) {
          Object.defineProperty(obj, key, {
            value: value,
            enumerable: true,
            configurable: true,
            writable: true
          });
        } else {
          obj[key] = value;
        }
        return obj;
      }
      function _toPrimitive(input, hint) {
        if (typeof input !== "object" || input === null) return input;
        var prim = input[Symbol.toPrimitive];
        if (prim !== undefined) {
          var res = prim.call(input, hint || "default");
          if (typeof res !== "object") return res;
          throw new TypeError("@@toPrimitive must return a primitive value.");
        }
        return (hint === "string" ? String : Number)(input);
      }
      function _toPropertyKey(arg) {
        var key = _toPrimitive(arg, "string");
        return typeof key === "symbol" ? key : String(key);
      }

      var _hoisted_1$1 = {
        class: "row"
      };
      var _hoisted_2$1 = {
        class: "col-md-6"
      };
      var _hoisted_3 = {
        class: "col-md-6"
      };
      var _hoisted_4 = {
        class: "row"
      };
      var _hoisted_5 = {
        class: "col-md-6"
      };
      var _hoisted_6 = {
        key: 0
      };
      var _hoisted_7 = {
        class: "col-md-6"
      };
      var _hoisted_8 = {
        class: "row"
      };
      var _hoisted_9 = {
        class: "col-md-6"
      };
      var _hoisted_10 = {
        class: "col-md-6"
      };
      createElementVNode("span", {
        class: "input-group-addon"
      }, "seconds", -1);
      var script$1 = defineComponent({
        name: 'editPanel.partial',
        props: {
          modelValue: {
            type: Object,
            required: true
          },
          options: {
            type: Object,
            required: true
          }
        },
        emits: ["update:modelValue", "propertyChanged"],
        setup(__props, _ref) {
          var _props$modelValue$att, _props$modelValue$att2, _props$modelValue$nam, _props$modelValue$isA, _props$modelValue$des, _props$modelValue$cod, _props$options$httpMe, _props$modelValue$slu, _props$modelValue$htt, _props$modelValue$ena, _props$modelValue$cac, _props$modelValue$rat, _props$modelValue$rat2, _props$options$securi, _props$modelValue$sec, _props$modelValue$ena2;
          var emit = _ref.emit;
          var props = __props;
          var invokeBlockAction = useInvokeBlockAction();
          var attributes = ref((_props$modelValue$att = props.modelValue.attributes) !== null && _props$modelValue$att !== void 0 ? _props$modelValue$att : {});
          var attributeValues = ref((_props$modelValue$att2 = props.modelValue.attributeValues) !== null && _props$modelValue$att2 !== void 0 ? _props$modelValue$att2 : {});
          var name = propertyRef((_props$modelValue$nam = props.modelValue.name) !== null && _props$modelValue$nam !== void 0 ? _props$modelValue$nam : "", "Name");
          var isActive = propertyRef((_props$modelValue$isA = props.modelValue.isActive) !== null && _props$modelValue$isA !== void 0 ? _props$modelValue$isA : false, "IsActive");
          var description = propertyRef((_props$modelValue$des = props.modelValue.description) !== null && _props$modelValue$des !== void 0 ? _props$modelValue$des : "", "Description");
          var codeTemplate = propertyRef((_props$modelValue$cod = props.modelValue.codeTemplate) !== null && _props$modelValue$cod !== void 0 ? _props$modelValue$cod : "", "CodeTemplate");
          var httpMethodOptions = ref((_props$options$httpMe = props.options.httpMethodOptions) !== null && _props$options$httpMe !== void 0 ? _props$options$httpMe : []);
          var slug = propertyRef((_props$modelValue$slu = props.modelValue.slug) !== null && _props$modelValue$slu !== void 0 ? _props$modelValue$slu : "", "Slug");
          var httpMethod = propertyRef((_props$modelValue$htt = props.modelValue.httpMethod) === null || _props$modelValue$htt === void 0 ? void 0 : _props$modelValue$htt.toString(), "HttpMethod");
          var enabledLavaCommands = propertyRef((_props$modelValue$ena = props.modelValue.enabledLavaCommands) !== null && _props$modelValue$ena !== void 0 ? _props$modelValue$ena : [], "EnabledLavaCommands");
          var cacheControlHeaderSettings = propertyRef((_props$modelValue$cac = props.modelValue.cacheControlHeaderSettings) !== null && _props$modelValue$cac !== void 0 ? _props$modelValue$cac : null, "CacheControlHeaderSettings");
          var rateLimitPeriodDurationSeconds = propertyRef((_props$modelValue$rat = props.modelValue.rateLimitPeriodDurationSeconds) !== null && _props$modelValue$rat !== void 0 ? _props$modelValue$rat : null, "RateLimitPeriodDurationSeconds");
          var rateLimitRequestPerPeriod = propertyRef((_props$modelValue$rat2 = props.modelValue.rateLimitRequestPerPeriod) !== null && _props$modelValue$rat2 !== void 0 ? _props$modelValue$rat2 : null, "RateLimitRequestPerPeriod");
          var securityModeOptions = ref((_props$options$securi = props.options.securityModeOptions) !== null && _props$options$securi !== void 0 ? _props$options$securi : []);
          var securityMode = propertyRef((_props$modelValue$sec = props.modelValue.securityMode) === null || _props$modelValue$sec === void 0 ? void 0 : _props$modelValue$sec.toString(), "SecurityMode");
          var enableCrossSiteForgeryProtection = propertyRef((_props$modelValue$ena2 = props.modelValue.enableCrossSiteForgeryProtection) !== null && _props$modelValue$ena2 !== void 0 ? _props$modelValue$ena2 : true, "EnableCrossSiteForgeryProtection");
          var slugError = ref("");
          var propRefs = [name, isActive, description, slug, httpMethod, codeTemplate, enabledLavaCommands, securityMode, cacheControlHeaderSettings, rateLimitPeriodDurationSeconds, rateLimitRequestPerPeriod, enableCrossSiteForgeryProtection];
          function onSlugChange() {
            return _onSlugChange.apply(this, arguments);
          }
          function _onSlugChange() {
            _onSlugChange = _asyncToGenerator(function* () {
              var result = yield invokeBlockAction("ValidateRoute", {
                slug: slug.value,
                method: toNumberOrNull(httpMethod.value)
              });
              if (result.isSuccess) {
                console.log(result);
                if (result.data === true) {
                  slugError.value = "The slug is already in use.";
                } else {
                  slugError.value = "";
                }
              } else {
                console.error(result.errorMessage || "An error occurred while validating the slug.");
              }
            });
            return _onSlugChange.apply(this, arguments);
          }
          watch(() => props.modelValue, () => {
            var _props$modelValue$att3, _props$modelValue$att4, _props$modelValue$nam2, _props$modelValue$isA2, _props$modelValue$des2, _props$modelValue$slu2, _props$modelValue$htt2, _props$modelValue$htt3, _props$modelValue$cod2, _props$modelValue$ena3, _props$modelValue$cac2, _props$modelValue$rat3, _props$modelValue$rat4, _props$modelValue$sec2, _props$modelValue$sec3, _props$modelValue$ena4;
            updateRefValue(attributes, (_props$modelValue$att3 = props.modelValue.attributes) !== null && _props$modelValue$att3 !== void 0 ? _props$modelValue$att3 : {});
            updateRefValue(attributeValues, (_props$modelValue$att4 = props.modelValue.attributeValues) !== null && _props$modelValue$att4 !== void 0 ? _props$modelValue$att4 : {});
            updateRefValue(name, (_props$modelValue$nam2 = props.modelValue.name) !== null && _props$modelValue$nam2 !== void 0 ? _props$modelValue$nam2 : "");
            updateRefValue(isActive, (_props$modelValue$isA2 = props.modelValue.isActive) !== null && _props$modelValue$isA2 !== void 0 ? _props$modelValue$isA2 : false);
            updateRefValue(description, (_props$modelValue$des2 = props.modelValue.description) !== null && _props$modelValue$des2 !== void 0 ? _props$modelValue$des2 : "");
            updateRefValue(slug, (_props$modelValue$slu2 = props.modelValue.slug) !== null && _props$modelValue$slu2 !== void 0 ? _props$modelValue$slu2 : "");
            updateRefValue(httpMethod, (_props$modelValue$htt2 = (_props$modelValue$htt3 = props.modelValue.httpMethod) === null || _props$modelValue$htt3 === void 0 ? void 0 : _props$modelValue$htt3.toString()) !== null && _props$modelValue$htt2 !== void 0 ? _props$modelValue$htt2 : "");
            updateRefValue(codeTemplate, (_props$modelValue$cod2 = props.modelValue.codeTemplate) !== null && _props$modelValue$cod2 !== void 0 ? _props$modelValue$cod2 : "");
            updateRefValue(enabledLavaCommands, (_props$modelValue$ena3 = props.modelValue.enabledLavaCommands) !== null && _props$modelValue$ena3 !== void 0 ? _props$modelValue$ena3 : []);
            updateRefValue(cacheControlHeaderSettings, (_props$modelValue$cac2 = props.modelValue.cacheControlHeaderSettings) !== null && _props$modelValue$cac2 !== void 0 ? _props$modelValue$cac2 : null);
            updateRefValue(rateLimitPeriodDurationSeconds, (_props$modelValue$rat3 = props.modelValue.rateLimitPeriodDurationSeconds) !== null && _props$modelValue$rat3 !== void 0 ? _props$modelValue$rat3 : null);
            updateRefValue(rateLimitRequestPerPeriod, (_props$modelValue$rat4 = props.modelValue.rateLimitRequestPerPeriod) !== null && _props$modelValue$rat4 !== void 0 ? _props$modelValue$rat4 : null);
            updateRefValue(securityMode, (_props$modelValue$sec2 = (_props$modelValue$sec3 = props.modelValue.securityMode) === null || _props$modelValue$sec3 === void 0 ? void 0 : _props$modelValue$sec3.toString()) !== null && _props$modelValue$sec2 !== void 0 ? _props$modelValue$sec2 : "");
            updateRefValue(enableCrossSiteForgeryProtection, (_props$modelValue$ena4 = props.modelValue.enableCrossSiteForgeryProtection) !== null && _props$modelValue$ena4 !== void 0 ? _props$modelValue$ena4 : true);
          });
          watch([attributeValues, ...propRefs], () => {
            var newValue = _objectSpread2(_objectSpread2({}, props.modelValue), {}, {
              attributeValues: attributeValues.value,
              name: name.value,
              isActive: isActive.value,
              description: description.value,
              httpMethod: toNumberOrNull(httpMethod.value),
              slug: slug.value,
              codeTemplate: codeTemplate.value,
              enabledLavaCommands: enabledLavaCommands.value,
              cacheControlHeaderSettings: cacheControlHeaderSettings.value,
              rateLimitPeriodDurationSeconds: rateLimitPeriodDurationSeconds.value,
              rateLimitRequestPerPeriod: rateLimitRequestPerPeriod.value,
              securityMode: toNumberOrNull(securityMode.value),
              enableCrossSiteForgeryProtection: enableCrossSiteForgeryProtection.value
            });
            emit("update:modelValue", newValue);
          });
          watchPropertyChanges(propRefs, emit);
          return (_ctx, _cache) => {
            return openBlock(), createElementBlock("fieldset", null, [createElementVNode("div", _hoisted_1$1, [createElementVNode("div", _hoisted_2$1, [createVNode(unref(TextBox), {
              modelValue: unref(name),
              "onUpdate:modelValue": _cache[0] || (_cache[0] = $event => isRef(name) ? name.value = $event : null),
              label: "Name",
              rules: "required"
            }, null, 8, ["modelValue"])]), createElementVNode("div", _hoisted_3, [createVNode(unref(CheckBox), {
              modelValue: unref(isActive),
              "onUpdate:modelValue": _cache[1] || (_cache[1] = $event => isRef(isActive) ? isActive.value = $event : null),
              label: "Active"
            }, null, 8, ["modelValue"])])]), createVNode(unref(TextBox), {
              modelValue: unref(description),
              "onUpdate:modelValue": _cache[2] || (_cache[2] = $event => isRef(description) ? description.value = $event : null),
              label: "Description",
              textMode: "multiline"
            }, null, 8, ["modelValue"]), createElementVNode("div", _hoisted_4, [createElementVNode("div", _hoisted_5, [createVNode(unref(TextBox), {
              modelValue: unref(slug),
              "onUpdate:modelValue": _cache[3] || (_cache[3] = $event => isRef(slug) ? slug.value = $event : null),
              help: "The slug to use for this endpoint.",
              label: "Slug",
              rules: "required",
              onBlur: onSlugChange
            }, null, 8, ["modelValue"]), slugError.value ? (openBlock(), createElementBlock("div", _hoisted_6, toDisplayString(slugError.value), 1)) : createCommentVNode("v-if", true)]), createElementVNode("div", _hoisted_7, [createVNode(unref(RadioButtonList), {
              modelValue: unref(httpMethod),
              "onUpdate:modelValue": _cache[4] || (_cache[4] = $event => isRef(httpMethod) ? httpMethod.value = $event : null),
              items: httpMethodOptions.value,
              horizontal: "",
              label: "HTTP Method",
              rules: "required",
              help: "The HTTP method for this endpoint."
            }, null, 8, ["modelValue", "items"])])]), createElementVNode("div", _hoisted_8, [createElementVNode("div", _hoisted_9, [createVNode(unref(RadioButtonList), {
              modelValue: unref(securityMode),
              "onUpdate:modelValue": _cache[5] || (_cache[5] = $event => isRef(securityMode) ? securityMode.value = $event : null),
              items: securityModeOptions.value,
              horizontal: "",
              label: "Security Mode",
              rules: "required",
              help: "Determines how security will be determined for the application. Block Integrated will use the security passed from the block. Custom will use the security configured on the backend application and endpoints."
            }, null, 8, ["modelValue", "items"])]), createElementVNode("div", _hoisted_10, [createVNode(unref(CheckBox), {
              modelValue: unref(enableCrossSiteForgeryProtection),
              "onUpdate:modelValue": _cache[6] || (_cache[6] = $event => isRef(enableCrossSiteForgeryProtection) ? enableCrossSiteForgeryProtection.value = $event : null),
              label: "Enable Cross-Site Forgery Protection",
              help: "When enabled the endpoint will check for a cross-site header for all requests. The Helix Content block provides this header automatically. We strongly encourage you to keep this setting enabled."
            }, null, 8, ["modelValue"])])]), createVNode(unref(CodeEditor), {
              modelValue: unref(codeTemplate),
              "onUpdate:modelValue": _cache[7] || (_cache[7] = $event => isRef(codeTemplate) ? codeTemplate.value = $event : null),
              label: "Code Template",
              theme: "rock",
              mode: "text",
              help: "Your Lava template. Note that the application's configuration rigging is available as 'ConfigurationRigging'.",
              editorHeight: 600
            }, null, 8, ["modelValue"]), createVNode(unref(LavaCommandPicker), {
              modelValue: unref(enabledLavaCommands),
              "onUpdate:modelValue": _cache[8] || (_cache[8] = $event => isRef(enabledLavaCommands) ? enabledLavaCommands.value = $event : null),
              label: "Enabled Lava Commands",
              enhanceForLongLists: false,
              multiple: ""
            }, null, 8, ["modelValue"]), createVNode(unref(AttributeValuesContainer), {
              modelValue: attributeValues.value,
              "onUpdate:modelValue": _cache[9] || (_cache[9] = $event => attributeValues.value = $event),
              showCategoryLabel: false,
              attributes: attributes.value,
              isEditMode: "",
              numberOfColumns: 2
            }, null, 8, ["modelValue", "attributes"]), createVNode(unref(Panel), {
              title: "Advanced Settings",
              hasCollapse: true,
              hasFullscreen: false,
              isFullscreenPageOnly: true
            }, {
              default: withCtx(() => [createVNode(unref(CacheabilityPicker), {
                modelValue: unref(cacheControlHeaderSettings),
                "onUpdate:modelValue": _cache[10] || (_cache[10] = $event => isRef(cacheControlHeaderSettings) ? cacheControlHeaderSettings.value = $event : null),
                showBlankItem: false,
                multiple: false
              }, null, 8, ["modelValue"]), createCommentVNode("v-if", true)]),
              _: 1
            })]);
          };
        }
      });

      script$1.__file = "src/tech_triumph/LavaHelix/LavaEndpointDetail/editPanel.partial.obs";

      var NavigationUrlKey = function (NavigationUrlKey) {
        NavigationUrlKey["ParentPage"] = "ParentPage";
        return NavigationUrlKey;
      }({});

      var _hoisted_1 = createTextVNode(" Save ");
      var _hoisted_2 = createTextVNode(" Cancel ");
      var script = exports('default', defineComponent({
        name: 'lavaEndpointDetail',
        setup(__props) {
          var _config$entity;
          var config = useConfigurationValues();
          var invokeBlockAction = useInvokeBlockAction();
          var securityGrant = getSecurityGrant(config.securityGrantToken);
          var blockError = ref("");
          var errorMessage = ref("");
          var lavaEndpointEditBag = ref((_config$entity = config.entity) !== null && _config$entity !== void 0 ? _config$entity : {});
          var isSaving = ref(false);
          var isNavigating = ref(false);
          var submitForm = ref(false);
          var resetKey = ref("");
          var showAuditDetailsModal = ref(false);
          var entityTypeGuid = "";
          var validProperties = ["attributeValues", "description", "isActive", "name", "codeTemplate", "slug", "httpMethod", "enabledLavaCommands", "rateLimitPeriodDurationSeconds", "rateLimitRequestPerPeriod", "cacheControlHeaderSettings", "securityMode"];
          var entityKey = computed(() => {
            var _lavaEndpointEditBag$, _lavaEndpointEditBag$2;
            return (_lavaEndpointEditBag$ = (_lavaEndpointEditBag$2 = lavaEndpointEditBag.value) === null || _lavaEndpointEditBag$2 === void 0 ? void 0 : _lavaEndpointEditBag$2.idKey) !== null && _lavaEndpointEditBag$ !== void 0 ? _lavaEndpointEditBag$ : "";
          });
          var panelTitle = computed(() => {
            return lavaEndpointEditBag.value.idKey ? "Edit Lava Endpoint" : "Add Lava Endpoint";
          });
          var options = computed(() => {
            var _config$options;
            return (_config$options = config.options) !== null && _config$options !== void 0 ? _config$options : {};
          });
          var secondaryActions = computed(() => {
            var _lavaEndpointEditBag$3;
            var actions = [];
            if (lavaEndpointEditBag !== null && lavaEndpointEditBag !== void 0 && (_lavaEndpointEditBag$3 = lavaEndpointEditBag.value) !== null && _lavaEndpointEditBag$3 !== void 0 && _lavaEndpointEditBag$3.idKey) {
              actions.push({
                type: "default",
                title: "Audit Details",
                handler: onAuditClick
              });
            }
            return actions;
          });
          var onAuditClick = () => {
            showAuditDetailsModal.value = true;
          };
          function onCancel() {
            var _config$navigationUrl;
            if ((_config$navigationUrl = config.navigationUrls) !== null && _config$navigationUrl !== void 0 && _config$navigationUrl[NavigationUrlKey.ParentPage]) {
              isNavigating.value = true;
              window.location.href = makeUrlRedirectSafe(config.navigationUrls[NavigationUrlKey.ParentPage]);
            }
          }
          function onSave() {
            return _onSave.apply(this, arguments);
          }
          function _onSave() {
            _onSave = _asyncToGenerator(function* () {
              errorMessage.value = "";
              var data = {
                entity: lavaEndpointEditBag.value,
                isEditable: true,
                validProperties: validProperties
              };
              var result = yield invokeBlockAction("Save", {
                box: data
              });
              if (result.isSuccess && result.data) {
                if (typeof result.data === "string") {
                  var _config$navigationUrl2;
                  if ((_config$navigationUrl2 = config.navigationUrls) !== null && _config$navigationUrl2 !== void 0 && _config$navigationUrl2[NavigationUrlKey.ParentPage]) {
                    window.location.href = makeUrlRedirectSafe(result.data);
                  }
                }
              } else {
                var _result$errorMessage;
                errorMessage.value = (_result$errorMessage = result.errorMessage) !== null && _result$errorMessage !== void 0 ? _result$errorMessage : "Unknown error while trying to save  lava endpoint.";
              }
            });
            return _onSave.apply(this, arguments);
          }
          var onStartSubmitForm = () => {
            submitForm.value = true;
          };
          provideSecurityGrant(securityGrant);
          if (config.errorMessage) {
            blockError.value = config.errorMessage;
          } else if (!config.entity) {
            blockError.value = "The specified lava endpoint could not be viewed.";
          }
          return (_ctx, _cache) => {
            return openBlock(), createElementBlock(Fragment, null, [blockError.value ? (openBlock(), createBlock(unref(NotificationBox), {
              key: 0,
              alertType: "warning"
            }, {
              default: withCtx(() => [createTextVNode(toDisplayString(blockError.value), 1)]),
              _: 1
            })) : createCommentVNode("v-if", true), errorMessage.value ? (openBlock(), createBlock(unref(NotificationBox), {
              key: 1,
              alertType: "danger"
            }, {
              default: withCtx(() => [createTextVNode(toDisplayString(errorMessage.value), 1)]),
              _: 1
            })) : createCommentVNode("v-if", true), createVNode(unref(RockForm), {
              submit: submitForm.value,
              "onUpdate:submit": _cache[2] || (_cache[2] = $event => submitForm.value = $event),
              onSubmit: onSave,
              formResetKey: resetKey.value
            }, {
              default: withCtx(() => [createVNode(unref(Panel), {
                title: unref(panelTitle),
                headerSecondaryActions: unref(secondaryActions)
              }, {
                footerActions: withCtx(() => [createVNode(unref(RockButton), {
                  btnSize: unref(BtnSize).Default,
                  btnType: unref(BtnType).Primary,
                  isLoading: isSaving.value,
                  onClick: onStartSubmitForm
                }, {
                  default: withCtx(() => [_hoisted_1]),
                  _: 1
                }, 8, ["btnSize", "btnType", "isLoading"]), createVNode(unref(RockButton), {
                  btnSize: unref(BtnSize).Default,
                  btnType: unref(BtnType).Link,
                  onClick: onCancel
                }, {
                  default: withCtx(() => [_hoisted_2]),
                  _: 1
                }, 8, ["btnSize", "btnType"])]),
                default: withCtx(() => [createVNode(unref(script$1), {
                  modelValue: lavaEndpointEditBag.value,
                  "onUpdate:modelValue": _cache[0] || (_cache[0] = $event => lavaEndpointEditBag.value = $event),
                  options: unref(options)
                }, null, 8, ["modelValue", "options"]), createVNode(unref(Modal), {
                  modelValue: showAuditDetailsModal.value,
                  "onUpdate:modelValue": _cache[1] || (_cache[1] = $event => showAuditDetailsModal.value = $event),
                  title: "Audit Details"
                }, {
                  default: withCtx(() => [createVNode(unref(AuditDetail), {
                    entityTypeGuid: entityTypeGuid,
                    entityKey: unref(entityKey)
                  }, null, 8, ["entityKey"])]),
                  _: 1
                }, 8, ["modelValue"])]),
                _: 1
              }, 8, ["title", "headerSecondaryActions"])]),
              _: 1
            }, 8, ["submit", "formResetKey"])], 64);
          };
        }
      }));

      script.__file = "src/tech_triumph/LavaHelix/lavaEndpointDetail.obs";

    })
  };
}));
//# sourceMappingURL=lavaEndpointDetail.obs.js.map
