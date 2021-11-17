import std/[macros, sugar, genasts, enumerate]

type
  ResetableClosure = concept r
    r.data is tuple
    r.theProc is proc
    r.theIter is iterator

iterator `[]`*[T](a: openArray[T], slice: Slice[int]): T =
  ## Immutable slice iteration over an `openarray`
  for x in a.toOpenArray(slice.a, slice.b):
    yield x

iterator `[]`*[T](a: openArray[T], slice: HSlice[int, BackwardsIndex]): T =
  ## Immutable slice iteration over an `openarray`, taking `BackwardsIndex`
  for x in a[slice.a .. a.len - slice.b.int]:
    yield x

iterator `{}`*[T](a: var openArray[T], slice: Slice[int]): var T =
  ## Mutable slice iteration over an `openarray`
  for i in slice.a..slice.b:
    yield a[i]

iterator `{}`*[T](a: var openArray[T], slice: HSlice[int, BackwardsIndex]): var T =
  ## Mutable slice iteration over an `openarray`, taking `BackwardsIndex`
  for ch in a{slice.a .. a.len - slice.b.int}:
    yield ch

iterator revItems*[T](a: openArray[T]): T =
  ## Reversed immutable items over an `openArray`
  for x in countdown(a.high, 0):
    yield a[x]

iterator revMitems*[T](a: var openArray[T]): var T =
  ## Reversed mutable items over an `openArray`
  for x in countdown(a.high, 0):
    yield a[x]

iterator findAll*[T](a: openArray[T], val: T): int =
  ## Iterates the `openArray` yielding indices that match `val`
  for i, x in a:
    if x == val:
      yield i

iterator mFindAll*[T](a: var openArray[T], val: T): var T =
  ## Iterates the `openarray` yielding mutable values that match `val`
  for i, x in a:
    if x == val:
      yield a[i]

iterator rFindAll*[T](a: openArray[T], val: T): int =
  ## Iterates the `openArray` backwards yield all indices that match `val`
  var i = a.high
  for x in a.revItems:
    if x == val:
      yield i
    dec i

iterator rMFindAll*[T](a: var openArray[T], val: T): var T =
  ## Iterates the `openArray` backwards yielding all mutable values that match `val`
  for x in a.revMitems:
    if x == val:
      yield x

template forMItems*[T](a: var openArray[T], indexName, valName, body: untyped): untyped =
  ## Sugar for iterating over mutable entries getting their indices and value
  var index = 0
  for valname in a.mitems:
    let indexName = index
    body
    inc index

proc generateClosure(iter: NimNode): NimNode =
  let
    iter = copyNimTree(iter)
    impl = getImpl(iter[0])

  for i in countdown(impl[4].len - 1, 0): 
    let x = impl[4][i]
    if x.eqIdent("closure"):
      error("cannot convert closure to closure", iter[0])

  let
    procName = genSym(nskProc, "closureImpl")
    call = newCall(procName)

  for i in 1 .. iter.len - 1: # Unpacks the values if they're converted
    if iter[i].kind == nnkHiddenStdConv:
      iter[i] = iter[i][^1]
    call.add iter[i].copyNimTree()

  var paramList = collect(newSeq):
    for i, x in impl[3]:
      let def = x.copyNimTree()
      if i > 0:
        def[^2] = getTypeInst(iter[i])
      def

  var vars = 1 # For each variable
  for i, defs in paramList:
    if i > 0:
      for j, def in defs[0..^3]:
        defs[j] = genSym(nskParam, $def) # Replace params with new symbol
        iter[vars] = defs[j] # Changes call parameter aswell
        inc vars

  let
    res = ident"result"
    body = genast(iter, res):
      res = iterator(): auto {.closure.} =
        for x in iter:
          yield x

  paramList[0] = ident"auto" # Set return type to auto

  result = newProc(procName, paramList, body) # make proc
  result = nnkBlockStmt.newTree(newEmptyNode(), newStmtList(result, call)) # make block statment

macro asClosure*(iter: iterable): untyped =
  ## Takes a call to an iterator and captures it in a closure iterator for easy usage.
  iter.generateClosure()

template skipIter*(iter, val: untyped, toSkip: Natural, body: untyped) =
  ## Skip over a certain number of iterations
  for i, x in enumerate(iter):
    if i > toSkip:
      let val = x
      body

template iterRange*(iter, val: untyped, rng: Slice[int], body: untyped) =
  ## Only runs code for a given range of iterations
  for i, x in enumerate(iter):
    if i in rng:
      let val = x
      body

macro asResetableClosure*(iter: iterable): untyped =
  var tupleData = nnkTupleConstr.newTree()
  for x in iter[1..^1]:
    tupleData.add:
      case x.kind
      of nnkHiddenStdConv, nnkConv:
        x[^1]
      else:
        x
  let
    closure = generateClosure(iter)
    closureProc = closure[1][0][0]
  result =
    genAst(closure, closureProc, tupleData):
      block:
        let clos = closure
        type AnonResetClos = object
          data: typeof(tupleData)
          theProc: typeof(closureProc)
          theIter: typeof(clos)
        AnonResetClos(data: tupleData, theProc: closureProc, theIter: clos)

macro `<-`(prc: proc, data: tuple): untyped =
  result = newCall(prc)
  for i, _ in data.getTypeInst:
    result.add nnkBracketExpr.newTree(data, newLit(i))

proc reset*(rc: var ResetableClosure) =
  rc.theIter = rc.theProc <- rc.data

iterator items*(rc: var ResetableClosure, reset = false): char =
  for x in rc.theIter():
    yield x
  if reset:
    reset(rc)

macro nameConstr(t: typed, useNew: static bool): untyped =
  var t = getType(t)
  if t[0].eqIdent("typedesc"):
    t = t[^1]
  let
    isGeneric = t.kind == nnkBracketExpr
    name =
      if useNew:
        "new"
      else:
        "init"
    procName = ident name & (
      if isGeneric:
        $t[0]
      else:
        $t)
  result =
    if isGeneric:
      newCall(nnkBracketExpr.newTree(procName, t[^1]))
    else:
      newCall(procName)

template isNew(b, B): untyped =
  nameConstr(b, true) is B

template isInit(b, B): untyped =
  nameConstr(b, false) is B

type
  BuiltInInit = concept b, type B
    isInit(b, B)
  BuiltInNew = concept b, type B
    isNew(b, B)
  UserInited = concept u, type U
    init(U) is U
  UserNewed = concept u, type U
    new(U) is U

proc getLastCall(n: NimNode): NimNode =
  result = n
  while result.kind != nnkCall:
    result = result[^1]

proc insertResCall(n, procName: NimNode) =
  for x in n:
    if x.kind == nnkCall and x[0].kind == nnkIdent and x[0].eqIdent procName:
      x.insert(1, ident"res")
    else:
      x.insertResCall(procName)

macro collectIn*(collection: typedesc, body: untyped): untyped =
  ## Much like `std/sugar`.
  ## Supply a type that you want to, then call the proc to add the value
  ## in the last statement.
  ## Use accquoted procedures to avoid the replacement by the system
  runnableExamples:
    let a = collectIn(seq[int]):
      for x in 0..3:
        add(x)
    assert a == @[1, 2, 3, 4]
    proc incl(s: var string, b: string) = discard
    let c = collectIn(HashSet[int]):
      for x in 1..3:
        var a = "hello"
        `incl`(a, "Hello") # notice ``incl`` to avoid turning into `incl(a, res, "hello")`
        if x == 2:
          incl(x)
        else:
          incl(10)

  let lastCall = getLastCall(body)
  body.insertResCall(lastCall[0])

  result = genAst(body, collection, res = ident"res"):
    block:
      var res =
        when collection is BuiltInInit:
          namedConstr(collection, false)
        elif collection is BuiltInNew:
          nameConstr(collection, true)
        elif collection is UserInited:
          init(collection)
        elif collection is UserNewed or collection is ref:
          new(collection)
        else:
          collection()
      body
      res
