{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveDataTypeable, DeriveGeneric #-}
-- |
-- Module    : Statistics.Distribution.Lognormal
-- Copyright : (c) 2020 Ximin Luo
-- License   : BSD3
--
-- Maintainer  : infinity0@pwned.gg
-- Stability   : experimental
-- Portability : portable
--
-- The weibull distribution.  This is a continuous probability
-- distribution that describes the occurrence of a single event whose
-- probability changes over time, controlled by the shape parameter.

module Statistics.Distribution.Weibull
    (
      WeibullDistribution
      -- * Constructors
    , weibullDistr
    , weibullDistrE
    , weibullStandard
    , weibullDistrApproxMeanStddevE
    ) where

import Control.Applicative
import Data.Aeson            (FromJSON(..), ToJSON, Value(..), (.:))
import Data.Binary           (Binary(..))
import Data.Data             (Data, Typeable)
import Data.Maybe            (fromMaybe)
import GHC.Generics          (Generic)
import Numeric.MathFunctions.Constants (m_eulerMascheroni)
import Numeric.SpecFunctions (expm1, log1p, logGamma)
import qualified Data.Vector.Generic as G

import qualified Statistics.Distribution as D
import qualified Statistics.Sample as S
import Statistics.Internal


-- | The weibull distribution.
data WeibullDistribution = WD {
      wdShape  :: {-# UNPACK #-} !Double
    , wdLambda :: {-# UNPACK #-} !Double
    } deriving (Eq, Typeable, Data, Generic)

instance Show WeibullDistribution where
  showsPrec i (WD k l) = defaultShow2 "weibullDistr" k l i
instance Read WeibullDistribution where
  readPrec = defaultReadPrecM2 "weibullDistr" weibullDistrE

instance ToJSON WeibullDistribution
instance FromJSON WeibullDistribution where
  parseJSON (Object v) = do
    k <- v .: "wdShape"
    l <- v .: "wdLambda"
    maybe (fail $ errMsg k l) return $ weibullDistrE k l
  parseJSON _ = empty

instance Binary WeibullDistribution where
  put (WD k l) = put k >> put l
  get = do
    k <- get
    l <- get
    maybe (fail $ errMsg k l) return $ weibullDistrE k l

instance D.Distribution WeibullDistribution where
  cumulative      = cumulative
  complCumulative = complCumulative

instance D.ContDistr WeibullDistribution where
  logDensity    = logDensity
  quantile      = quantile
  complQuantile = complQuantile

instance D.MaybeMean WeibullDistribution where
  maybeMean = Just . D.mean

instance D.Mean WeibullDistribution where
  mean (WD k l) = l * exp (logGamma (1 + 1 / k))

instance D.MaybeVariance WeibullDistribution where
  maybeStdDev   = Just . D.stdDev
  maybeVariance = Just . D.variance

instance D.Variance WeibullDistribution where
  variance (WD k l) = l * l * (exp (logGamma (1 + 2 * invk)) - q * q)
   where
    invk = 1 / k
    q    = exp (logGamma (1 + invk))

instance D.Entropy WeibullDistribution where
  entropy (WD k l) = m_eulerMascheroni * (1 - 1 / k) + log (l / k) + 1

instance D.MaybeEntropy WeibullDistribution where
  maybeEntropy = Just . D.entropy

instance D.ContGen WeibullDistribution where
  genContVar d = D.genContinuous d

-- | Standard weibull distribution with scale factor (lambda) 1.
weibullStandard :: Double -> WeibullDistribution
weibullStandard k = weibullDistr k 1.0

-- | Create weibull distribution from parameters.
--
-- If the shape (first) parameter is @1.0@, the distribution is equivalent to a
-- 'Statistics.Distribution.Exponential.ExponentialDistribution' with parameter
-- @1 / lambda@ the scale (second) parameter.
weibullDistr
  :: Double            -- ^ Shape
  -> Double            -- ^ Lambda (scale)
  -> WeibullDistribution
weibullDistr k l = fromMaybe (error $ errMsg k l) $ weibullDistrE k l

-- | Create weibull distribution from parameters.
--
-- If the shape (first) parameter is @1.0@, the distribution is equivalent to a
-- 'Statistics.Distribution.Exponential.ExponentialDistribution' with parameter
-- @1 / lambda@ the scale (second) parameter.
weibullDistrE
  :: Double            -- ^ Shape
  -> Double            -- ^ Lambda (scale)
  -> Maybe WeibullDistribution
weibullDistrE k l | k <= 0     = Nothing
                  | l <= 0     = Nothing
                  | otherwise = Just $ WD k l

errMsg :: Double -> Double -> String
errMsg k l =
  "Statistics.Distribution.Weibull.weibullDistr: both shape and lambda must be positive. Got shape "
    ++ show k
    ++ " and lambda "
    ++ show l

-- | Create weibull distribution from mean and standard deviation.
--
-- The algorithm is from "Methods for Estimating Wind Speed Frequency
-- Distributions", C. G. Justus, W. R. Hargreaves, A. Mikhail, D. Graber, 1977.
-- Given the identity:
--
-- \[
-- (\frac{\sigma}{\mu})^2 = \frac{\Gamma(1+2/k)}{\Gamma(1+1/k)^2} - 1
-- \]
--
-- \(k\) can be approximated by
--
-- \[
-- k \approx (\frac{\sigma}{\mu})^{-1.086}
-- \]
--
-- \(\lambda\) is then calculated straightforwardly via the identity
--
-- \[
-- \lambda = \frac{\mu}{\Gamma(1+1/k)}
-- \]
--
-- Numerically speaking, the approximation for \(k\) is accurate only within a
-- certain range. We arbitrarily pick the range \(0.033 \le \frac{\sigma}{\mu} \le 1.45\)
-- where it is good to ~6%, and will refuse to create a distribution outside of
-- this range. The paper does not cover these details but it is straightforward
-- to check them numerically.
weibullDistrApproxMeanStddevE
  :: Double            -- ^ Mean
  -> Double            -- ^ Stddev
  -> Maybe WeibullDistribution
weibullDistrApproxMeanStddevE m s = if r > 1.45 || r < 0.033
    then Nothing
    else weibullDistrE k l
  where r = s / m
        k = (s / m) ** (-1.086)
        l = m / exp (logGamma (1 + 1/k))

-- | Uses an approximation based on the mean and standard deviation in
--   'weibullDistrEstMeanStddevE', with standard deviation estimated
--   using maximum likelihood method (unbiased estimation).
--
--   Returns @Nothing@ if sample contains less than one element or
--   variance is zero (all elements are equal), or if the estimated mean
--   and standard-deviation lies outside the range for which the
--   approximation is accurate.
instance D.FromSample WeibullDistribution Double where
  fromSample xs
    | G.length xs <= 1 = Nothing
    | v == 0           = Nothing
    | otherwise        = weibullDistrApproxMeanStddevE m (sqrt v)
    where
      (m,v) = S.meanVarianceUnb xs

logDensity :: WeibullDistribution -> Double -> Double
logDensity (WD k l) x
  | x < 0     = 0
  | otherwise = log k + (k - 1) * log x - k * log l - (x / l) ** k

cumulative :: WeibullDistribution -> Double -> Double
cumulative (WD k l) x | x < 0     = 0
                      | otherwise = -expm1 (-(x / l) ** k)

complCumulative :: WeibullDistribution -> Double -> Double
complCumulative (WD k l) x | x < 0     = 1
                           | otherwise = exp (-(x / l) ** k)

quantile :: WeibullDistribution -> Double -> Double
quantile (WD k l) p
  | p == 0         = 0
  | p == 1         = inf
  | p > 0 && p < 1 = l * (-log1p (-p)) ** (1 / k)
  | otherwise      =
    error $ "Statistics.Distribution.Weibull.quantile: p must be in [0,1] range. Got: " ++ show p
  where inf = 1 / 0

complQuantile :: WeibullDistribution -> Double -> Double
complQuantile (WD k l) q
  | q == 0         = inf
  | q == 1         = 0
  | q > 0 && q < 1 = l * (-log q) ** (1 / k)
  | otherwise      =
    error $ "Statistics.Distribution.Weibull.complQuantile: q must be in [0,1] range. Got: " ++ show q
  where inf = 1 / 0
