module Language.Haskell.Exference.FunctionBinding
  ( FunctionBinding
  , RatedFunctionBinding
  , Context
  )
where



import Language.Haskell.Exference.Type
import Language.Haskell.Exference.ConstrainedType
import Language.Haskell.Exference.TypeClasses



type FunctionBinding = (String, HsConstrainedType)
type RatedFunctionBinding = (String, Float, HsConstrainedType)

type Context = ([RatedFunctionBinding], StaticContext)
