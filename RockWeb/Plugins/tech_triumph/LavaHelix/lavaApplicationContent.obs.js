System.register(['vue', '@Obsidian/Utility/block'], (function (exports) {
  'use strict';
  var defineComponent, resolveDirective, withDirectives, openBlock, createElementBlock, unref, useStaticContent;
  return {
    setters: [function (module) {
      defineComponent = module.defineComponent;
      resolveDirective = module.resolveDirective;
      withDirectives = module.withDirectives;
      openBlock = module.openBlock;
      createElementBlock = module.createElementBlock;
      unref = module.unref;
    }, function (module) {
      useStaticContent = module.useStaticContent;
    }],
    execute: (function () {

      var script = exports('default', defineComponent({
        name: 'lavaApplicationContent',
        setup(__props) {
          var content = useStaticContent();
          return (_ctx, _cache) => {
            var _directive_content = resolveDirective("content");
            return withDirectives((openBlock(), createElementBlock("div", null, null, 512)), [[_directive_content, unref(content)]]);
          };
        }
      }));

      script.__file = "src/tech_triumph/LavaHelix/lavaApplicationContent.obs";

    })
  };
}));
//# sourceMappingURL=lavaApplicationContent.obs.js.map
