System.register(['vue', '@Obsidian/Utility/block', '@Obsidian/Controls/grid', '@Obsidian/Utility/dialogs'], (function (exports) {
  'use strict';
  var defineComponent, ref, resolveComponent, openBlock, createBlock, unref, withCtx, createVNode, createElementBlock, createCommentVNode, reactive, useConfigurationValues, useInvokeBlockAction, Grid, TextColumn, textValueFilter, pickExistingValueFilter, BooleanColumn, SecurityColumn, DeleteColumn, alert;
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

      var _hoisted_1 = {
        key: 0,
        class: "label label-success"
      };
      var _hoisted_2 = {
        key: 1,
        class: "label label-danger"
      };
      var script = exports('default', defineComponent({
        name: 'lavaApplicationList',
        setup(__props) {
          var config = useConfigurationValues();
          var invokeBlockAction = useInvokeBlockAction();
          var gridDataSource = ref();
          var gridData;
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
                yield alert((_result$errorMessage2 = result.errorMessage) !== null && _result$errorMessage2 !== void 0 ? _result$errorMessage2 : "Unknown error while trying to delete lava application.");
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
            return openBlock(), createBlock(unref(Grid), {
              definition: (_unref$gridDefinition = unref(config).gridDefinition) !== null && _unref$gridDefinition !== void 0 ? _unref$gridDefinition : undefined,
              data: gridDataSource.value,
              keyField: "idKey",
              itemTerm: "Lava Application",
              entityTypeGuid: "FFFE0DE1-B410-435E-9AA8-3A0B18AAF0F7",
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
              }, null, 8, ["filter"]), createVNode(_component_Column, {
                name: "Status",
                title: "Status",
                field: "isActive",
                filter: unref(pickExistingValueFilter),
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
            }, 8, ["definition", "data", "expectedRowCount", "onAddItem"]);
          };
        }
      }));

      script.__file = "src/tech_triumph/LavaHelix/lavaApplicationList.obs";

    })
  };
}));
//# sourceMappingURL=lavaApplicationList.obs.js.map
