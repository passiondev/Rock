System.register(['vue', '@Obsidian/Controls/notificationBox.obs', '@Obsidian/Templates/detailBlock', '@Obsidian/Enums/Controls/detailPanelMode', '@Obsidian/Controls/attributeValuesContainer.obs', '@Obsidian/Controls/checkBox.obs', '@Obsidian/Controls/textBox.obs', '@Obsidian/Utility/block', '@Obsidian/Utility/component', '@Obsidian/Controls/codeEditor.obs', '@Obsidian/Controls/valueDetailList.obs', '@Obsidian/Core/Controls/valueDetailListItemBuilder', '@Obsidian/Controls/rockButton.obs', '@Obsidian/Controls/modal.obs', '@Obsidian/Utility/util'], (function (exports) {
  'use strict';
  var defineComponent, ref, watch, openBlock, createElementBlock, createElementVNode, createVNode, unref, isRef, createTextVNode, computed, withCtx, toDisplayString, createCommentVNode, Fragment, createBlock, NotificationBox, DetailBlock, DetailPanelMode, AttributeValuesContainer, CheckBox, TextBox, watchPropertyChanges, useConfigurationValues, useInvokeBlockAction, getSecurityGrant, refreshDetailAttributes, provideSecurityGrant, onConfigurationValuesChanged, useReloadBlock, propertyRef, updateRefValue, CodeEditor, ValueDetailList, ValueDetailListItemBuilder, RockButton, Modal, debounce;
  return {
    setters: [function (module) {
      defineComponent = module.defineComponent;
      ref = module.ref;
      watch = module.watch;
      openBlock = module.openBlock;
      createElementBlock = module.createElementBlock;
      createElementVNode = module.createElementVNode;
      createVNode = module.createVNode;
      unref = module.unref;
      isRef = module.isRef;
      createTextVNode = module.createTextVNode;
      computed = module.computed;
      withCtx = module.withCtx;
      toDisplayString = module.toDisplayString;
      createCommentVNode = module.createCommentVNode;
      Fragment = module.Fragment;
      createBlock = module.createBlock;
    }, function (module) {
      NotificationBox = module["default"];
    }, function (module) {
      DetailBlock = module["default"];
    }, function (module) {
      DetailPanelMode = module.DetailPanelMode;
    }, function (module) {
      AttributeValuesContainer = module["default"];
    }, function (module) {
      CheckBox = module["default"];
    }, function (module) {
      TextBox = module["default"];
    }, function (module) {
      watchPropertyChanges = module.watchPropertyChanges;
      useConfigurationValues = module.useConfigurationValues;
      useInvokeBlockAction = module.useInvokeBlockAction;
      getSecurityGrant = module.getSecurityGrant;
      refreshDetailAttributes = module.refreshDetailAttributes;
      provideSecurityGrant = module.provideSecurityGrant;
      onConfigurationValuesChanged = module.onConfigurationValuesChanged;
      useReloadBlock = module.useReloadBlock;
    }, function (module) {
      propertyRef = module.propertyRef;
      updateRefValue = module.updateRefValue;
    }, function (module) {
      CodeEditor = module["default"];
    }, function (module) {
      ValueDetailList = module["default"];
    }, function (module) {
      ValueDetailListItemBuilder = module.ValueDetailListItemBuilder;
    }, function (module) {
      RockButton = module["default"];
    }, function (module) {
      Modal = module["default"];
    }, function (module) {
      debounce = module.debounce;
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
      var _hoisted_3$1 = {
        class: "col-md-6"
      };
      var _hoisted_4$1 = {
        class: "row"
      };
      var _hoisted_5$1 = {
        class: "col-md-6"
      };
      var _hoisted_6$1 = {
        class: "row"
      };
      var _hoisted_7$1 = {
        class: "col-md-6"
      };
      var script$2 = defineComponent({
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
          var _props$modelValue$att, _props$modelValue$att2, _props$modelValue$nam, _props$modelValue$isA, _props$modelValue$des, _props$modelValue$con, _props$modelValue$slu;
          var emit = _ref.emit;
          var props = __props;
          var attributes = ref((_props$modelValue$att = props.modelValue.attributes) !== null && _props$modelValue$att !== void 0 ? _props$modelValue$att : {});
          var attributeValues = ref((_props$modelValue$att2 = props.modelValue.attributeValues) !== null && _props$modelValue$att2 !== void 0 ? _props$modelValue$att2 : {});
          var name = propertyRef((_props$modelValue$nam = props.modelValue.name) !== null && _props$modelValue$nam !== void 0 ? _props$modelValue$nam : "", "Name");
          var isActive = propertyRef((_props$modelValue$isA = props.modelValue.isActive) !== null && _props$modelValue$isA !== void 0 ? _props$modelValue$isA : false, "IsActive");
          var description = propertyRef((_props$modelValue$des = props.modelValue.description) !== null && _props$modelValue$des !== void 0 ? _props$modelValue$des : "", "Description");
          var configurationRigging = propertyRef((_props$modelValue$con = props.modelValue.configurationRigging) !== null && _props$modelValue$con !== void 0 ? _props$modelValue$con : "", "ConfigurationRigging");
          var slug = propertyRef((_props$modelValue$slu = props.modelValue.slug) !== null && _props$modelValue$slu !== void 0 ? _props$modelValue$slu : "", "Slug");
          var propRefs = [name, isActive, description, slug, configurationRigging];
          watch(() => props.modelValue, () => {
            var _props$modelValue$att3, _props$modelValue$att4, _props$modelValue$nam2, _props$modelValue$isA2, _props$modelValue$des2, _props$modelValue$slu2, _props$modelValue$con2;
            updateRefValue(attributes, (_props$modelValue$att3 = props.modelValue.attributes) !== null && _props$modelValue$att3 !== void 0 ? _props$modelValue$att3 : {});
            updateRefValue(attributeValues, (_props$modelValue$att4 = props.modelValue.attributeValues) !== null && _props$modelValue$att4 !== void 0 ? _props$modelValue$att4 : {});
            updateRefValue(name, (_props$modelValue$nam2 = props.modelValue.name) !== null && _props$modelValue$nam2 !== void 0 ? _props$modelValue$nam2 : "");
            updateRefValue(isActive, (_props$modelValue$isA2 = props.modelValue.isActive) !== null && _props$modelValue$isA2 !== void 0 ? _props$modelValue$isA2 : false);
            updateRefValue(description, (_props$modelValue$des2 = props.modelValue.description) !== null && _props$modelValue$des2 !== void 0 ? _props$modelValue$des2 : "");
            updateRefValue(slug, (_props$modelValue$slu2 = props.modelValue.slug) !== null && _props$modelValue$slu2 !== void 0 ? _props$modelValue$slu2 : "");
            updateRefValue(configurationRigging, (_props$modelValue$con2 = props.modelValue.configurationRigging) !== null && _props$modelValue$con2 !== void 0 ? _props$modelValue$con2 : "");
          });
          watch([attributeValues, ...propRefs], () => {
            var newValue = _objectSpread2(_objectSpread2({}, props.modelValue), {}, {
              attributeValues: attributeValues.value,
              name: name.value,
              isActive: isActive.value,
              description: description.value,
              slug: slug.value,
              configurationRigging: configurationRigging.value
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
            }, null, 8, ["modelValue"])]), createElementVNode("div", _hoisted_3$1, [createVNode(unref(CheckBox), {
              modelValue: unref(isActive),
              "onUpdate:modelValue": _cache[1] || (_cache[1] = $event => isRef(isActive) ? isActive.value = $event : null),
              label: "Active"
            }, null, 8, ["modelValue"])])]), createVNode(unref(TextBox), {
              modelValue: unref(description),
              "onUpdate:modelValue": _cache[2] || (_cache[2] = $event => isRef(description) ? description.value = $event : null),
              label: "Description",
              textMode: "multiline"
            }, null, 8, ["modelValue"]), createElementVNode("div", _hoisted_4$1, [createElementVNode("div", _hoisted_5$1, [createVNode(unref(TextBox), {
              modelValue: unref(slug),
              "onUpdate:modelValue": _cache[3] || (_cache[3] = $event => isRef(slug) ? slug.value = $event : null),
              help: "The slug to use for the application.",
              label: "Slug",
              rules: "required"
            }, null, 8, ["modelValue"])])]), createVNode(unref(CodeEditor), {
              modelValue: unref(configurationRigging),
              "onUpdate:modelValue": _cache[4] || (_cache[4] = $event => isRef(configurationRigging) ? configurationRigging.value = $event : null),
              label: "Configuration Rigging",
              theme: "rock",
              mode: "text",
              editorHeight: 400,
              help: "Use this field to specify your application's configuration settings in JSON format. It provides a structured way to customize your application's settings. You can reference this configuration as an object in your endpoint template using the merge field 'ConfigurationRigging'."
            }, null, 8, ["modelValue"]), createElementVNode("div", _hoisted_6$1, [createElementVNode("div", _hoisted_7$1, [createVNode(unref(AttributeValuesContainer), {
              modelValue: attributeValues.value,
              "onUpdate:modelValue": _cache[5] || (_cache[5] = $event => attributeValues.value = $event),
              showCategoryLabel: false,
              attributes: attributes.value,
              isEditMode: "",
              numberOfColumns: 2
            }, null, 8, ["modelValue", "attributes"])])])]);
          };
        }
      });

      script$2.__file = "src/tech_triumph/LavaHelix/LavaApplicationDetail/editPanel.partial.obs";

      var _hoisted_1 = {
        class: "row"
      };
      var _hoisted_2 = {
        class: "col-md-6"
      };
      var _hoisted_3 = {
        class: "col-md-6"
      };
      var _hoisted_4 = {
        key: 0
      };
      var _hoisted_5 = createElementVNode("dt", null, "Configuration Rigging", -1);
      var _hoisted_6 = createElementVNode("i", {
        class: "fa fa-search"
      }, null, -1);
      var _hoisted_7 = createTextVNode("  ");
      var _hoisted_8 = {
        key: 0,
        class: "label label-warning"
      };
      var _hoisted_9 = {
        key: 0
      };
      var _hoisted_10 = createElementVNode("label", {
        style: {
          "font-weight": "normal",
          "font-size": "medium"
        }
      }, "JSON output", -1);
      var script$1 = defineComponent({
        name: 'viewPanel.partial',
        props: {
          modelValue: {
            type: Object,
            required: false
          },
          options: {
            type: Object,
            required: true
          }
        },
        setup(__props) {
          var _props$modelValue$att, _props$modelValue, _props$modelValue$att2, _props$modelValue2, _props$modelValue3;
          var props = __props;
          var isModalOpen = ref(false);
          var attributes = ref((_props$modelValue$att = (_props$modelValue = props.modelValue) === null || _props$modelValue === void 0 ? void 0 : _props$modelValue.attributes) !== null && _props$modelValue$att !== void 0 ? _props$modelValue$att : {});
          var attributeValues = ref((_props$modelValue$att2 = (_props$modelValue2 = props.modelValue) === null || _props$modelValue2 === void 0 ? void 0 : _props$modelValue2.attributeValues) !== null && _props$modelValue$att2 !== void 0 ? _props$modelValue$att2 : {});
          var configurationRigging = ref((_props$modelValue3 = props.modelValue) === null || _props$modelValue3 === void 0 ? void 0 : _props$modelValue3.configurationRigging);
          var jsonData = ref("");
          var jsonErrorMessage = ref("");
          var topValues = computed(() => {
            var valueBuilder = new ValueDetailListItemBuilder();
            if (!props.modelValue) {
              return valueBuilder.build();
            }
            if (props.modelValue.description) {
              valueBuilder.addTextValue("", props.modelValue.description);
            }
            return valueBuilder.build();
          });
          var leftSideValues = computed(() => {
            var valueBuilder = new ValueDetailListItemBuilder();
            if (!props.modelValue) {
              return valueBuilder.build();
            }
            valueBuilder.addTextValue("Slug", props.modelValue.slug ? props.modelValue.slug.toString() : "None");
            return valueBuilder.build();
          });
          var rightSideValues = computed(() => {
            var valueBuilder = new ValueDetailListItemBuilder();
            if (!props.modelValue) {
              return valueBuilder.build();
            }
            return valueBuilder.build();
          });
          function onPreviewClick() {
            return _onPreviewClick.apply(this, arguments);
          }
          function _onPreviewClick() {
            _onPreviewClick = _asyncToGenerator(function* () {
              var _props$modelValue4;
              if ((_props$modelValue4 = props.modelValue) !== null && _props$modelValue4 !== void 0 && _props$modelValue4.configurationRigging) {
                if (isJsonString(props.modelValue.configurationRigging)) {
                  isModalOpen.value = true;
                  jsonData.value = JSON.stringify(JSON.parse(props.modelValue.configurationRigging), undefined, 2);
                } else {
                  jsonErrorMessage.value = "Invalid JSON Detected";
                }
              }
            });
            return _onPreviewClick.apply(this, arguments);
          }
          function onClose() {
            isModalOpen.value = false;
          }
          function isJsonString(str) {
            try {
              JSON.parse(str);
            } catch (_unused) {
              return false;
            }
            return true;
          }
          return (_ctx, _cache) => {
            return openBlock(), createElementBlock("fieldset", null, [createVNode(unref(ValueDetailList), {
              modelValue: unref(topValues)
            }, null, 8, ["modelValue"]), createElementVNode("div", _hoisted_1, [createElementVNode("div", _hoisted_2, [createVNode(unref(ValueDetailList), {
              modelValue: unref(leftSideValues)
            }, null, 8, ["modelValue"])]), createElementVNode("div", _hoisted_3, [createVNode(unref(ValueDetailList), {
              modelValue: unref(rightSideValues)
            }, null, 8, ["modelValue"]), configurationRigging.value ? (openBlock(), createElementBlock("dl", _hoisted_4, [_hoisted_5, createElementVNode("dd", null, [createVNode(unref(RockButton), {
              btnType: "default",
              btnSize: "sm",
              onClick: onPreviewClick
            }, {
              default: withCtx(() => [_hoisted_6]),
              _: 1
            }), _hoisted_7, jsonErrorMessage.value ? (openBlock(), createElementBlock("span", _hoisted_8, toDisplayString(jsonErrorMessage.value), 1)) : createCommentVNode("v-if", true)])])) : createCommentVNode("v-if", true)])]), createVNode(unref(AttributeValuesContainer), {
              modelValue: attributeValues.value,
              attributes: attributes.value,
              numberOfColumns: 2
            }, null, 8, ["modelValue", "attributes"]), createVNode(unref(Modal), {
              modelValue: isModalOpen.value,
              "onUpdate:modelValue": _cache[0] || (_cache[0] = $event => isModalOpen.value = $event),
              title: "Preview the Configuration Rigging JSON",
              onClose: onClose,
              cancelText: 'OK'
            }, {
              default: withCtx(() => [jsonData.value ? (openBlock(), createElementBlock("div", _hoisted_9, [_hoisted_10, createElementVNode("pre", null, toDisplayString(jsonData.value), 1)])) : createCommentVNode("v-if", true)]),
              _: 1
            }, 8, ["modelValue"])]);
          };
        }
      });

      script$1.__file = "src/tech_triumph/LavaHelix/LavaApplicationDetail/viewPanel.partial.obs";

      var NavigationUrlKey = function (NavigationUrlKey) {
        NavigationUrlKey["ParentPage"] = "ParentPage";
        return NavigationUrlKey;
      }({});

      var script = exports('default', defineComponent({
        name: 'lavaApplicationDetail',
        setup(__props) {
          var config = useConfigurationValues();
          var invokeBlockAction = useInvokeBlockAction();
          var securityGrant = getSecurityGrant(config.securityGrantToken);
          var blockError = ref("");
          var errorMessage = ref("");
          var lavaApplicationViewBag = ref(config.entity);
          var lavaApplicationEditBag = ref({});
          var entityTypeGuid = "FFFE0DE1-B410-435E-9AA8-3A0B18AAF0F7";
          var panelMode = ref(DetailPanelMode.View);
          var validProperties = ["attributeValues", "description", "isActive", "name", "configurationRigging", "slug"];
          var refreshAttributesDebounce = debounce(() => refreshDetailAttributes(lavaApplicationEditBag, validProperties, invokeBlockAction), undefined, true);
          var panelName = computed(() => {
            var _lavaApplicationViewB, _lavaApplicationViewB2;
            return (_lavaApplicationViewB = (_lavaApplicationViewB2 = lavaApplicationViewBag.value) === null || _lavaApplicationViewB2 === void 0 ? void 0 : _lavaApplicationViewB2.name) !== null && _lavaApplicationViewB !== void 0 ? _lavaApplicationViewB : "";
          });
          var panelTitle = computed(() => {
            var _lavaApplicationViewB3, _lavaApplicationViewB4;
            switch (panelMode.value) {
              case DetailPanelMode.Add:
                return "Add Lava Application";
              case DetailPanelMode.Edit:
                return "Edit Lava Application";
              default:
                return (_lavaApplicationViewB3 = (_lavaApplicationViewB4 = lavaApplicationViewBag.value) === null || _lavaApplicationViewB4 === void 0 ? void 0 : _lavaApplicationViewB4.name) !== null && _lavaApplicationViewB3 !== void 0 ? _lavaApplicationViewB3 : "";
            }
          });
          var entityKey = computed(() => {
            var _lavaApplicationViewB5, _lavaApplicationViewB6;
            return (_lavaApplicationViewB5 = (_lavaApplicationViewB6 = lavaApplicationViewBag.value) === null || _lavaApplicationViewB6 === void 0 ? void 0 : _lavaApplicationViewB6.idKey) !== null && _lavaApplicationViewB5 !== void 0 ? _lavaApplicationViewB5 : "";
          });
          var blockLabels = computed(() => {
            var _lavaApplicationViewB7;
            var labels = [];
            if (panelMode.value !== DetailPanelMode.View) {
              return undefined;
            }
            if (((_lavaApplicationViewB7 = lavaApplicationViewBag.value) === null || _lavaApplicationViewB7 === void 0 ? void 0 : _lavaApplicationViewB7.isActive) === true) {
              labels.push({
                iconCssClass: "fa fa-lightbulb",
                title: "Active",
                type: "success"
              });
            } else {
              labels.push({
                iconCssClass: "far fa-lightbulb",
                title: "Inactive",
                type: "danger"
              });
            }
            return labels;
          });
          var isEditable = computed(() => {
            return config.isEditable === true;
          });
          var options = computed(() => {
            var _config$options;
            return (_config$options = config.options) !== null && _config$options !== void 0 ? _config$options : {};
          });
          function onCancelEdit() {
            return _onCancelEdit.apply(this, arguments);
          }
          function _onCancelEdit() {
            _onCancelEdit = _asyncToGenerator(function* () {
              var _lavaApplicationEditB;
              if (!((_lavaApplicationEditB = lavaApplicationEditBag.value) !== null && _lavaApplicationEditB !== void 0 && _lavaApplicationEditB.idKey)) {
                var _config$navigationUrl;
                if ((_config$navigationUrl = config.navigationUrls) !== null && _config$navigationUrl !== void 0 && _config$navigationUrl[NavigationUrlKey.ParentPage]) {
                  return config.navigationUrls[NavigationUrlKey.ParentPage];
                }
                return false;
              }
              return true;
            });
            return _onCancelEdit.apply(this, arguments);
          }
          function onDelete() {
            return _onDelete.apply(this, arguments);
          }
          function _onDelete() {
            _onDelete = _asyncToGenerator(function* () {
              var _lavaApplicationViewB8;
              errorMessage.value = "";
              var result = yield invokeBlockAction("Delete", {
                key: (_lavaApplicationViewB8 = lavaApplicationViewBag.value) === null || _lavaApplicationViewB8 === void 0 ? void 0 : _lavaApplicationViewB8.idKey
              });
              if (result.isSuccess && result.data) {
                return result.data;
              } else {
                var _result$errorMessage;
                errorMessage.value = (_result$errorMessage = result.errorMessage) !== null && _result$errorMessage !== void 0 ? _result$errorMessage : "Unknown error while trying to delete lava application.";
                return false;
              }
            });
            return _onDelete.apply(this, arguments);
          }
          function onEdit() {
            return _onEdit.apply(this, arguments);
          }
          function _onEdit() {
            _onEdit = _asyncToGenerator(function* () {
              var _lavaApplicationViewB9;
              var result = yield invokeBlockAction("Edit", {
                key: (_lavaApplicationViewB9 = lavaApplicationViewBag.value) === null || _lavaApplicationViewB9 === void 0 ? void 0 : _lavaApplicationViewB9.idKey
              });
              if (result.isSuccess && result.data && result.data.entity) {
                lavaApplicationEditBag.value = result.data.entity;
                return true;
              } else {
                return false;
              }
            });
            return _onEdit.apply(this, arguments);
          }
          function onPropertyChanged(propertyName) {
            if (!config.qualifiedAttributeProperties || !config.qualifiedAttributeProperties.some(n => n.toLowerCase() === propertyName.toLowerCase())) {
              return;
            }
            refreshAttributesDebounce();
          }
          function onSave() {
            return _onSave.apply(this, arguments);
          }
          function _onSave() {
            _onSave = _asyncToGenerator(function* () {
              var _result$errorMessage2;
              errorMessage.value = "";
              var data = {
                entity: lavaApplicationEditBag.value,
                isEditable: true,
                validProperties: validProperties
              };
              var result = yield invokeBlockAction("Save", {
                box: data
              });
              if (result.isSuccess && result.data) {
                if (result.statusCode === 200 && typeof result.data === "object") {
                  lavaApplicationViewBag.value = result.data;
                  return true;
                } else if ((result.statusCode === 201 || result.statusCode === 200) && typeof result.data === "string") {
                  return result.data;
                }
              }
              errorMessage.value = (_result$errorMessage2 = result.errorMessage) !== null && _result$errorMessage2 !== void 0 ? _result$errorMessage2 : "Unknown error while trying to save lava application.";
              return false;
            });
            return _onSave.apply(this, arguments);
          }
          provideSecurityGrant(securityGrant);
          if (config.errorMessage) {
            blockError.value = config.errorMessage;
          } else if (!config.entity) {
            blockError.value = "The specified lava application could not be viewed.";
          } else if (!config.entity.idKey) {
            lavaApplicationEditBag.value = config.entity;
            panelMode.value = DetailPanelMode.Add;
          }
          onConfigurationValuesChanged(useReloadBlock());
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
            })) : createCommentVNode("v-if", true), !blockError.value ? (openBlock(), createBlock(unref(DetailBlock), {
              key: 2,
              mode: panelMode.value,
              "onUpdate:mode": _cache[1] || (_cache[1] = $event => panelMode.value = $event),
              name: unref(panelName),
              title: unref(panelTitle),
              labels: unref(blockLabels),
              entityKey: unref(entityKey),
              entityTypeGuid: entityTypeGuid,
              entityTypeName: "LavaApplication",
              isAuditHidden: false,
              isBadgesVisible: true,
              isDeleteVisible: unref(isEditable),
              isEditVisible: unref(isEditable),
              isFullScreenVisible: false,
              isFollowVisible: false,
              isSecurityHidden: false,
              onCancelEdit: onCancelEdit,
              onDelete: onDelete,
              onEdit: onEdit,
              onSave: onSave
            }, {
              view: withCtx(() => [createVNode(unref(script$1), {
                modelValue: lavaApplicationViewBag.value,
                options: unref(options)
              }, null, 8, ["modelValue", "options"])]),
              edit: withCtx(() => [createVNode(unref(script$2), {
                modelValue: lavaApplicationEditBag.value,
                "onUpdate:modelValue": _cache[0] || (_cache[0] = $event => lavaApplicationEditBag.value = $event),
                options: unref(options),
                onPropertyChanged: onPropertyChanged
              }, null, 8, ["modelValue", "options"])]),
              _: 1
            }, 8, ["mode", "name", "title", "labels", "entityKey", "isDeleteVisible", "isEditVisible"])) : createCommentVNode("v-if", true)], 64);
          };
        }
      }));

      script.__file = "src/tech_triumph/LavaHelix/lavaApplicationDetail.obs";

    })
  };
}));
//# sourceMappingURL=lavaApplicationDetail.obs.js.map
