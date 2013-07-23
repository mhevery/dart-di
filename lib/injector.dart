part of di;

class Injector {
  final bool allowImplicitInjection;

  final List<Symbol> _PRIMITIVE_TYPES = <Symbol>[new Symbol('dynamic'),
      new Symbol('num'), new Symbol('int'), new Symbol('double'),
      new Symbol('String'), new Symbol('bool')];

  final Injector parent;

  Map<Symbol, _ProviderMetadata> providers =
      new Map<Symbol, _ProviderMetadata>();
  Map<Symbol, dynamic> instances = new Map<Symbol, dynamic>();

  List<Symbol> resolving = new List<Symbol>();

  Injector([List<Module> modules, bool allowImplicitInjection = true])
      : this._fromParent(modules, null, allowImplicitInjection: allowImplicitInjection);

  Injector._fromParent(List<Module> modules, Injector this.parent,
      {bool this.allowImplicitInjection: true}) {
    if (modules == null) {
      modules = <Module>[];
    }
    Module injectorModule = new Module();
    injectorModule.value(Injector, this);
    modules.add(injectorModule);
    modules.forEach((module) {
      providers.addAll(module._mappings);
    });
  }

  String _error(message, [appendDependency]) {
    if (appendDependency != null) {
      resolving.add(appendDependency);
    }

    String graph = resolving.map(formatSymbol).join(' -> ');

    resolving.clear();

    return '$message (resolving $graph)';
  }

  dynamic _getInstanceBySymbol(Symbol typeName, {bool cache: true,
      bool direct: false, Map<Type, dynamic> locals, getInstanceBySymbol,
      Injector requester}) {
    _checkTypeConditions(typeName);

    if (resolving.contains(typeName)) {
      throw new CircularDependencyException(
          _error('Cannot resolve a circular dependency!', typeName));
    }

    // TODO(pavelgj): Think of a simpler way.
    if (!direct) {
      getInstanceBySymbol =
          _wrapGetInstanceBySymbol(_getInstanceBySymbol, requester);
    }

    var provider = _getProviderForSymbol(typeName);
    var metadata = provider.first;
    var visible = metadata.visibility(requester, provider.second);

    if (visible && instances.containsKey(typeName)) {
      return instances[typeName];
    }

    if (provider.second != this || !visible) {
      var injector = provider.second;
      if (!visible) {
        injector = provider.second.parent.
            _getProviderForSymbol(typeName).second;
      }
      return injector._getInstanceBySymbol(typeName, cache: cache,
          direct: direct, getInstanceBySymbol: getInstanceBySymbol,
          requester: requester);
    }

    var value;
    try {
      value = metadata.creation(typeName, requester, provider.second, direct, () {
        resolving.add(typeName);
        var val = metadata.provider.get(getInstanceBySymbol, _error);
        resolving.removeLast();
        return val;
      });
    } catch(e) {
      resolving.clear();
      throw e;
    }
    if (cache) {
      provider.second.instances[typeName] = value;
    }
    return value;
  }

  /**
   *  Wraps getInstanceBySymbol function with a requster value to be easily
   *  down to the providers.
   */
  Function _wrapGetInstanceBySymbol(Function getInstanceBySymbol,
                                    Injector requster) {
    return (Symbol typeName) {
      return getInstanceBySymbol(typeName, requester: requster);
    };
  }

  /// Returns a pair for provider and the injector where it's defined.
  _Pair<_ProviderMetadata, Injector> _getProviderForSymbol(Symbol typeName) {
    if (providers.containsKey(typeName)) {
      return new _Pair.of(providers[typeName], this);
    }

    if (parent != null) {
      return parent._getProviderForSymbol(typeName);
    }

    if (!allowImplicitInjection) {
      throw new NoProviderException(_error('No provider found for '
                                           '${formatSymbol(typeName)}!', typeName));
    }

    // create a provider for implicit types
    return new _Pair.of(
        new _ProviderMetadata(new _TypeProvider(typeName)), this);
  }

  void _checkTypeConditions(Symbol typeName) {
    if (_PRIMITIVE_TYPES.contains(typeName)) {
      throw new NoProviderException(_error('Cannot inject a primitive type '
          'of ${formatSymbol(typeName)}!', typeName));
    }
  }


  // PUBLIC API
  dynamic get(Type type) {
    return _getInstanceBySymbol(reflectClass(type).simpleName, requester: this);
  }

  dynamic instantiate(Type type, [Map<Type, dynamic> locals]) {
    Injector injector = this;

    if (locals != null && locals.isNotEmpty) {
      Module localsModule = new Module();
      for (Type key in locals.keys) {
        localsModule.value(key, locals[key]);
      }
      injector = createChild([localsModule]);
    }
    var symbol = reflectClass(type).simpleName;
    var wrappedGetInstance =
        _wrapGetInstanceBySymbol(injector._getInstanceBySymbol, this);
    var value = injector._getInstanceBySymbol(symbol, cache: false,
        direct: true,
        getInstanceBySymbol: wrappedGetInstance,
        requester: this);
    instances[symbol] = value;
    return value;
  }

  dynamic invoke(Function fn) {
    ClosureMirror cm = reflect(fn);
    MethodMirror mm = cm.function;
    List args = mm.parameters.map((ParameterMirror parameter) {
      return _getInstanceBySymbol(parameter.type.simpleName);
    }).toList();
    try {
      return cm.apply(args, null).reflectee;
    } on MirroredUncaughtExceptionError catch(e) {
      throw "${e}\nORIGINAL STACKTRACE\n${e.stacktrace}";
    }
  }

  Injector createChild(List<Module> modules, [List<Type> forceNewInstances]) {
    if (forceNewInstances != null) {
      Module forceNew = new Module();
      forceNewInstances.forEach((type) {
        forceNew.provider(type,
            _getProviderForSymbol(
                  reflectClass(type).simpleName).first.provider);
      });

      modules = modules.toList(); // clone
      modules.add(forceNew);
    }

    return new Injector._fromParent(modules, this);
  }
}

class _Pair<V1, V2> {
  final V1 first;
  final V2 second;
  _Pair.of(this.first, this.second);
}
