System.register(['vue', '@Obsidian/Utility/block', '@Obsidian/Controls/grid', '@Obsidian/Utility/dialogs'], (function (exports) {
  'use strict';
  var defineComponent, ref, resolveComponent, openBlock, createBlock, unref, withCtx, createVNode, createElementBlock, createCommentVNode, reactive, useConfigurationValues, useInvokeBlockAction, Grid, TextColumn, textValueFilter, LabelColumn, pickExistingValueFilter, BooleanColumn, SecurityColumn, DeleteColumn, alert;
  return {
    setters: [function (module) {
      defineComponent = module.defineComponent;
      ref = module.ref;
      resolveComponent = module.resolveComponent;
      openBlock = module.openBlock;
      createBlock = module.createBlock;
      unref = module.unref;
      withCtx = module.withCtx;
      createVNode = module.createVNode;
      createElementBlock = module.createElementBlock;
      createCommentVNode = module.createCommentVNode;
      reactive = module.reactive;
    }, function (module) {
      useConfigurationValues = module.useConfigurationValues;
      useInvokeBlockAction = module.useInvokeBlockAction;
    }, function (module) {
      Grid = module["default"];
      TextColumn = module.TextColumn;
      textValueFilter = module.textValueFilter;
      LabelColumn = module.LabelColumn;
      pickExistingValueFilter = module.pickExistingValueFilter;
      BooleanColumn = module.BooleanColumn;
      SecurityColumn = module.SecurityColumn;
      DeleteColumn = module.DeleteColumn;
    }, function (module) {
      alert = module.alert;
    }],
    execute: (function () {

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

      var NavigationUrlKey = function (NavigationUrlKey) {
        NavigationUrlKey["DetailPage"] = "DetailPage";
        return NavigationUrlKey;
      }({});

      var HttpMethod = {
        Get: 0,
        Post: 1,
        Put: 2,
        Delete: 3,
        Patch: 4
      };
      var HttpMethodDescription = {
        0: "Get",
        1: "Post",
        2: "Put",
        3: "Delete",
        4: "Patch"
      };

      var SecurityMode = {
        EndpointExecute: 0,
        ApplicationView: 1,
        ApplicationEdit: 2,
        ApplicationAdministrate: 3
      };
      var SecurityModeDescription = {
        0: "Endpoint Execute",
        1: "Application View",
        2: "Application Edit",
        3: "Application Administrate"
      };

      var _hoisted_1 = {
        key: 0,
        class: "label label-success"
      };
      var _hoisted_2 = {
        key: 1,
        class: "label label-danger"
      };
      var script = exports('default', defineComponent({
        name: 'lavaEndpointList',
        setup(__props) {
          var _config$options$isBlo, _config$options;
          var config = useConfigurationValues();
          var invokeBlockAction = useInvokeBlockAction();
          var isBlockVisible = ref((_config$options$isBlo = (_config$options = config.options) === null || _config$options === void 0 ? void 0 : _config$options.isBlockVisible) !== null && _config$options$isBlo !== void 0 ? _config$options$isBlo : false);
          var securityModeLabelColors = {
            [SecurityModeDescription[SecurityMode.EndpointExecute]]: "info",
            [SecurityModeDescription[SecurityMode.ApplicationView]]: "success",
            [SecurityModeDescription[SecurityMode.ApplicationEdit]]: "warning",
            [SecurityModeDescription[SecurityMode.ApplicationAdministrate]]: "danger"
          };
          var gridDataSource = ref();
          var gridData;
          var httpMethodLabelColors = {
            [HttpMethodDescription[HttpMethod.Get]]: "info",
            [HttpMethodDescription[HttpMethod.Post]]: "success",
            [HttpMethodDescription[HttpMethod.Put]]: "warning",
            [HttpMethodDescription[HttpMethod.Delete]]: "danger",
            [HttpMethodDescription[HttpMethod.Patch]]: "campus"
          };
          function loadGridData() {
            return _loadGridData.apply(this, arguments);
          }
          function _loadGridData() {
            _loadGridData = _asyncToGenerator(function* () {
              var result = yield invokeBlockAction("GetGridData");
              if (result.isSuccess && result.data) {
                gridData = reactive(result.data);
                return gridData;
              } else {
                var _result$errorMessage;
                throw new Error((_result$errorMessage = result.errorMessage) !== null && _result$errorMessage !== void 0 ? _result$errorMessage : "Unknown error while trying to load grid data.");
              }
            });
            return _loadGridData.apply(this, arguments);
          }
          function onSelectItem(key) {
            var _config$navigationUrl;
            if ((_config$navigationUrl = config.navigationUrls) !== null && _config$navigationUrl !== void 0 && _config$navigationUrl[NavigationUrlKey.DetailPage]) {
              window.location.href = config.navigationUrls[NavigationUrlKey.DetailPage].replace("((Key))", key);
            }
          }
          function onDeleteClick(_x) {
            return _onDeleteClick.apply(this, arguments);
          }
          function _onDeleteClick() {
            _onDeleteClick = _asyncToGenerator(function* (key) {
              var result = yield invokeBlockAction("Delete", {
                key
              });
              if (result.isSuccess) {
                if (gridData && gridData.rows) {
                  var index = gridData.rows.findIndex(r => r["idKey"] === key);
                  if (index !== -1) {
                    var _gridData$rows;
                    (_gridData$rows = gridData.rows) === null || _gridData$rows === void 0 ? void 0 : _gridData$rows.splice(index, 1);
                  }
                }
              } else {
                var _result$errorMessage2;
                yield alert((_result$errorMessage2 = result.errorMessage) !== null && _result$errorMessage2 !== void 0 ? _result$errorMessage2 : "Unknown error while trying to delete site.");
              }
            });
            return _onDeleteClick.apply(this, arguments);
          }
          function onAddItem() {
            var _config$navigationUrl2;
            if ((_config$navigationUrl2 = config.navigationUrls) !== null && _config$navigationUrl2 !== void 0 && _config$navigationUrl2[NavigationUrlKey.DetailPage]) {
              window.location.href = config.navigationUrls[NavigationUrlKey.DetailPage].replace("((Key))", "0");
            }
          }
          gridDataSource.value = loadGridData();
          return (_ctx, _cache) => {
            var _unref$gridDefinition, _unref$expectedRowCou;
            var _component_Column = resolveComponent("Column");
            return isBlockVisible.value ? (openBlock(), createBlock(unref(Grid), {
              key: 0,
              definition: (_unref$gridDefinition = unref(config).gridDefinition) !== null && _unref$gridDefinition !== void 0 ? _unref$gridDefinition : undefined,
              data: gridDataSource.value,
              keyField: "idKey",
              itemTerm: "Lava Endpoint",
              entityTypeGuid: "F1BBF7D4-CAFD-450D-A89A-B3312C9738A2",
              expectedRowCount: (_unref$expectedRowCou = unref(config).expectedRowCount) !== null && _unref$expectedRowCou !== void 0 ? _unref$expectedRowCou : undefined,
              tooltipField: "name",
              stickyHeader: "",
              liveUpdates: "",
              onAddItem: unref(config).isAddEnabled ? onAddItem : undefined,
              onSelectItem: onSelectItem
            }, {
              default: withCtx(() => [createVNode(unref(TextColumn), {
                name: "name",
                title: "Name",
                field: "name",
                filter: unref(textValueFilter),
                visiblePriority: "xs"
              }, null, 8, ["filter"]), createVNode(unref(TextColumn), {
                name: "slug",
                title: "Slug",
                field: "slug",
                filter: unref(textValueFilter),
                visiblePriority: "xs"
              }, null, 8, ["filter"]), createVNode(unref(LabelColumn), {
                name: "Http Method",
                title: "Method",
                field: "httpMethod",
                filter: unref(pickExistingValueFilter),
                textSource: unref(HttpMethodDescription),
                classSource: httpMethodLabelColors,
                width: "120",
                visiblePriority: "sm"
              }, null, 8, ["filter", "textSource"]), createVNode(unref(LabelColumn), {
                name: "Security Mode",
                title: "Security Mode",
                field: "securityMode",
                filter: unref(pickExistingValueFilter),
                textSource: unref(SecurityModeDescription),
                classSource: securityModeLabelColors,
                visiblePriority: "sm"
              }, null, 8, ["filter", "textSource"]), createVNode(_component_Column, {
                name: "Status",
                title: "Status",
                filter: unref(pickExistingValueFilter),
                field: "isActive",
                visiblePriority: "xs"
              }, {
                format: withCtx(_ref => {
                  var row = _ref.row;
                  return [row.isActive ? (openBlock(), createElementBlock("span", _hoisted_1, " Active ")) : (openBlock(), createElementBlock("span", _hoisted_2, " Inactive "))];
                }),
                _: 1
              }, 8, ["filter"]), createVNode(unref(BooleanColumn), {
                name: "System",
                title: "System",
                field: "isSystem",
                visiblePriority: "xs"
              }), createVNode(unref(SecurityColumn)), unref(config).isDeleteEnabled ? (openBlock(), createBlock(unref(DeleteColumn), {
                key: 0,
                onClick: onDeleteClick
              })) : createCommentVNode("v-if", true)]),
              _: 1
            }, 8, ["definition", "data", "expectedRowCount", "onAddItem"])) : createCommentVNode("v-if", true);
          };
        }
      }));

      script.__file = "src/tech_triumph/LavaHelix/lavaEndpointList.obs";

    })
  };
}));
//# sourceMappingURL=lavaEndpointList.obs.js.map
