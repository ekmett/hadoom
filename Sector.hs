{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE RecordWildCards #-}
module Sector where

import Prelude hiding (any, floor, ceiling, (.), id)

import Control.Applicative
import Data.Ord (comparing)
import Control.Category
import Control.Lens hiding (indices)
import Data.Foldable (any)
import Data.Int (Int32)
import Data.Monoid ((<>))
import Foreign (Storable(..), castPtr, nullPtr, plusPtr)
import Foreign.C (CFloat)
import Graphics.Rendering.OpenGL (($=))
import Linear as L

import qualified Data.IntMap.Strict as IM
import qualified Data.Vector as V
import qualified Data.Vector.Storable as SV
import qualified Graphics.Rendering.OpenGL as GL

import Geometry
import Material
import Shader

data Vertex =
  Vertex {vPos :: {-# UNPACK #-} !(V3 CFloat)
         ,vNorm :: {-# UNPACK #-} !(V3 CFloat)
         ,vTangent :: {-# UNPACK #-} !(V3 CFloat)
         ,vBitangent :: {-# UNPACK #-} !(V3 CFloat)
         ,vUV :: {-# UNPACK #-} !(V2 CFloat)}
  deriving (Show)


instance Storable Vertex where
  sizeOf ~(Vertex p n t bn uv) = sizeOf p + sizeOf n + sizeOf t + sizeOf bn +
                                 sizeOf uv
  alignment _ = 0
  peek ptr =
    Vertex <$>
    peek (castPtr ptr) <*>
    peek (castPtr $ ptr `plusPtr`
          sizeOf (vPos undefined)) <*>
    peek (castPtr $ ptr `plusPtr`
          sizeOf (vPos undefined) `plusPtr`
          sizeOf (vNorm undefined)) <*>
    peek (castPtr $ ptr `plusPtr`
          sizeOf (vPos undefined) `plusPtr`
          sizeOf (vNorm undefined) `plusPtr`
          sizeOf (vTangent undefined)) <*>
    peek (castPtr $ ptr `plusPtr`
          sizeOf (vPos undefined) `plusPtr`
          sizeOf (vNorm undefined) `plusPtr`
          sizeOf (vTangent undefined) `plusPtr`
          sizeOf (vBitangent undefined))
  poke ptr (Vertex p n t bn uv) =
    do poke (castPtr $ ptr) p
       poke (castPtr $ ptr `plusPtr` sizeOf p) n
       poke (castPtr $ ptr `plusPtr` sizeOf p `plusPtr` sizeOf n) t
       poke (castPtr $ ptr `plusPtr` sizeOf p `plusPtr` sizeOf n `plusPtr`
             sizeOf t)
            bn
       poke (castPtr $ ptr `plusPtr` sizeOf p `plusPtr` sizeOf n `plusPtr`
             sizeOf t `plusPtr` sizeOf bn)
            uv

data Blueprint =
  Blueprint {blueprintVertices :: IM.IntMap (V2 CFloat)
         ,blueprintWalls :: V.Vector (Int,Int)
         ,blueprintFloor :: CFloat
         ,blueprintCeiling :: CFloat
         ,blueprintFloorMaterial :: Material
         ,blueprintCeilingMaterial :: Material
         ,blueprintWallMaterial :: Material}

data Sector =
  Sector {sectorDrawWalls :: IO ()
                 ,sectorDrawFloor :: IO ()
                 ,sectorDrawCeiling :: IO ()
                 ,sectorFloorMaterial :: Material
                 ,sectorCeilingMaterial :: Material
                 ,sectorWallMaterial :: Material}

rayLineIntersection :: (Epsilon a,Fractional a,Ord a)
                    => V2 a -> V2 a -> V2 a -> V2 a -> Maybe (V2 a)
rayLineIntersection p r q q' =
  let s = q' - q
      cross (V2 a b) (V2 x y) = a * y - b * x
      pToQ = q - p
      tNum = pToQ `cross` s
      uNum = pToQ `cross` r
  in case r `cross` s of
       denom
         | nearZero denom -> Nothing
         | otherwise ->
           let u = uNum / denom
               t = tNum / denom
           in if 0 <= u && u <= 1
                 then Just (p + r ^* t)
                 else Nothing

makeSimple :: (Epsilon a,Fractional a,Ord a)
           => V.Vector (V2 a) -> V.Vector (V2 a) -> V.Vector (V2 a)
makeSimple inner outer =
  let xMost = comparing (view _x)
      m = V.maximumBy xMost inner
      mIndex = V.maxIndexBy xMost inner
      edges = V.zip outer (V.tail outer <> outer)
      intersections =
        V.map (\(start,end) ->
                 ((rayLineIntersection m
                                       (V2 1 0)
                                       start
                                       end)
                 ,start
                 ,end))
              edges
      (Just i,start,end) =
        V.minimumBy
          (\(x,_,_) (y,_,_) ->
             case (x,y) of
               (Nothing,Nothing) -> EQ
               (Just _,Nothing) -> LT
               (Nothing,Just _) -> GT
               (Just a,Just b) ->
                 comparing (qd m) a b)
          intersections
      p =
        V.maximumBy xMost
                    [start,end]
      containing =
        V.filter (pointInTriangle m i p .
                  snd) $
        V.filter (not . nearZero .
                  (subtract p) .
                  snd) $
        V.imap (,) outer
      isReflex _ = True
      angleAgainstM =
        dot (V2 1 0) .
        subtract m
      (minimalReflex,_) =
        V.minimumBy (comparing (angleAgainstM . snd))
                    (V.filter (isReflex . snd) containing)
  in if V.null containing
        then undefined
        else case V.splitAt minimalReflex outer of
               (before,after) ->
                 before <>
                 V.take 1 after <>
                 V.take (succ (V.length inner))
                        (V.drop mIndex inner <>
                         inner) <>
                 after

triangulate :: (Epsilon a, Fractional a, Ord a) => V.Vector (V2 a) -> V.Vector Int
triangulate = collapseAndTriangulate
  where collapseAndTriangulate vs = go $ addIndices vs
        takeFirst f =
          V.take 1 .
          V.filter f
        isEar ((_,a),(_,b),(_,c),otherVertices) =
          let area = triangleArea a b c
              containsOther =
                any (pointInTriangle a b c .
                     snd)
                    otherVertices
          in area > 0 && not containsOther
        go s
          | V.length s < 3 = empty
          | otherwise =
            do (v0@(n0,_),(n1,_),v2@(n2,_),others) <- takeFirst isEar (separate s)
               [n0,n2,n1] <>
                 go (v0 `V.cons`
                     (v2 `V.cons` others))
        addIndices vertices =
          V.zip [0 .. V.length vertices] vertices
        separate vertices =
          let n = V.length vertices
              doubleVerts = vertices <> vertices
          in V.zip4 vertices
                    (V.drop 1 doubleVerts)
                    (V.drop 2 doubleVerts)
                    (V.imap (\i _ ->
                               V.take (n - 3) $
                               V.drop (i + 3) $
                               doubleVerts)
                            vertices)
        -- collapse vs =
        --   V.map (\i ->
        --            let v = vs V.! i
        --            in fst $ V.head $ V.filter (nearZero . (v -) . snd) $ V.imap (,) vs)

buildSector :: Blueprint -> IO Sector
buildSector Blueprint{..} =
  do vao <- initializeVAO
     initializeVBO
     configureVertexAttributes
     initializeIBO
     return $
       Sector {sectorDrawWalls =
                 do GL.bindVertexArrayObject $=
                      Just vao
                    GL.drawElements GL.Triangles
                                    (fromIntegral $ V.length wallIndices)
                                    GL.UnsignedInt
                                    nullPtr
              ,sectorDrawFloor =
                 do GL.bindVertexArrayObject $=
                      Just vao
                    GL.drawElements
                      GL.Triangles
                      (fromIntegral $ V.length floorIndices)
                      GL.UnsignedInt
                      (nullPtr `plusPtr`
                       fromIntegral
                         (sizeOf (0 :: Int32) *
                          V.length wallIndices))
              ,sectorDrawCeiling =
                 do GL.bindVertexArrayObject $=
                      Just vao
                    GL.drawElements
                      GL.Triangles
                      (fromIntegral $ V.length ceilingIndices)
                      GL.UnsignedInt
                      (nullPtr `plusPtr`
                       fromIntegral
                         (sizeOf (0 :: Int32) *
                          (V.length wallIndices + V.length floorIndices)))
              ,sectorWallMaterial = blueprintWallMaterial
              ,sectorFloorMaterial = blueprintFloorMaterial
              ,sectorCeilingMaterial = blueprintCeilingMaterial}
  where initializeVAO =
          do vao <- GL.genObjectName :: IO (GL.VertexArrayObject)
             GL.bindVertexArrayObject $=
               Just vao
             return vao
        initializeVBO =
          do vbo <- GL.genObjectName
             GL.bindBuffer GL.ArrayBuffer $=
               Just vbo
             let vertices = wallVertices <> floorVertices <> ceilingVertices
             SV.unsafeWith (V.convert vertices) $
               \verticesPtr ->
                 GL.bufferData GL.ArrayBuffer $=
                 (fromIntegral
                    (V.length vertices *
                     sizeOf (undefined :: Vertex))
                 ,verticesPtr
                 ,GL.StaticDraw)
        configureVertexAttributes =
          do let stride =
                   fromIntegral $
                   sizeOf (undefined :: Vertex)
                 normalOffset =
                   fromIntegral $
                   sizeOf (0 :: V3 CFloat)
                 tangentOffset =
                   normalOffset +
                   fromIntegral (sizeOf (0 :: V3 CFloat))
                 bitangentOffset =
                   tangentOffset +
                   fromIntegral (sizeOf (0 :: V3 CFloat))
                 uvOffset =
                   bitangentOffset +
                   fromIntegral (sizeOf (0 :: V3 CFloat))
             GL.vertexAttribPointer positionAttribute $=
               (GL.ToFloat,GL.VertexArrayDescriptor 3 GL.Float stride nullPtr)
             GL.vertexAttribArray positionAttribute $= GL.Enabled
             GL.vertexAttribPointer normalAttribute $=
               (GL.ToFloat
               ,GL.VertexArrayDescriptor 3
                                         GL.Float
                                         stride
                                         (nullPtr `plusPtr` normalOffset))
             GL.vertexAttribArray normalAttribute $= GL.Enabled
             GL.vertexAttribPointer tangentAttribute $=
               (GL.ToFloat
               ,GL.VertexArrayDescriptor 3
                                         GL.Float
                                         stride
                                         (nullPtr `plusPtr` tangentOffset))
             GL.vertexAttribArray tangentAttribute $= GL.Enabled
             GL.vertexAttribPointer bitangentAttribute $=
               (GL.ToFloat
               ,GL.VertexArrayDescriptor 3
                                         GL.Float
                                         stride
                                         (nullPtr `plusPtr` bitangentOffset))
             GL.vertexAttribArray bitangentAttribute $= GL.Enabled
             GL.vertexAttribPointer uvAttribute $=
               (GL.ToFloat
               ,GL.VertexArrayDescriptor 2
                                         GL.Float
                                         stride
                                         (nullPtr `plusPtr` uvOffset))
             GL.vertexAttribArray uvAttribute $= GL.Enabled
        textureScaleFactor = 8.0e-2
        wallVertices =
          V.concatMap
            (\(s,e) ->
               expandEdge (blueprintVertices IM.! s)
                          (blueprintVertices IM.! e))
            blueprintWalls
          where expandEdge start@(V2 x1 y1) end@(V2 x2 y2) =
                  let wallV = end ^-^ start
                      wallLen = norm wallV
                      scaledLen = wallLen * textureScaleFactor
                      n =
                        case perp (wallV ^* recip wallLen) of
                          V2 x y -> V3 x 0 y
                      v =
                        (blueprintCeiling - blueprintFloor) *
                        textureScaleFactor
                  in V.fromList $ getZipList $ Vertex <$>
                     ZipList [V3 x1 blueprintFloor y1
                             ,V3 x1 blueprintCeiling y1
                             ,V3 x2 blueprintFloor y2
                             ,V3 x2 blueprintCeiling y2] <*>
                     ZipList (repeat n) <*>
                     ZipList (repeat $
                              case n of
                                V3 x 0 y ->
                                  V3 y 0 x) <*>
                     ZipList (repeat $
                              V3 0 (-1) 0) <*>
                     ZipList [V2 0 0,V2 0 v,V2 scaledLen 0,V2 scaledLen v]
        wallIndices =
          V.concatMap id $
          V.imap (\m _ ->
                    let n = m * 4
                    in V.map fromIntegral [n,n + 2,n + 1,n + 1,n + 2,n + 3])
                 blueprintWalls
        floorVertices =
          V.map (\(V2 x y) ->
                   Vertex (V3 x blueprintFloor y)
                          (V3 0 1 0)
                          (V3 1 0 0)
                          (V3 0 0 1)
                          (V2 x y ^*
                           textureScaleFactor))
                (V.fromList $ IM.elems blueprintVertices)
        ceilingVertices =
          V.map (\(Vertex p n t bn uv) ->
                   Vertex (p & _y .~ blueprintCeiling)
                          (negate n)
                          t
                          bn
                          uv)
                floorVertices
        floorIndices =
          let n = fromIntegral $ V.length wallVertices
          in fmap (fromIntegral . (+ n)) $
             triangulate (V.fromList $ IM.elems blueprintVertices)
        ceilingIndices =
          let reverseTriangles v =
                case V.splitAt 3 v of
                  (h,t)
                    | V.length h == 3 ->
                      [h V.! 0,h V.! 2,h V.! 1] V.++
                      reverseTriangles t
                  _ -> []
          in V.map (+ (fromIntegral $ V.length floorVertices))
                   (reverseTriangles floorIndices)
        initializeIBO =
          do let indices :: V.Vector Int32
                 indices = wallIndices <> floorIndices <> ceilingIndices
             ibo <- GL.genObjectName
             GL.bindBuffer GL.ElementArrayBuffer $=
               Just ibo
             SV.unsafeWith (V.convert indices) $
               \indicesPtr ->
                 GL.bufferData GL.ElementArrayBuffer $=
                 (fromIntegral
                    (V.length indices *
                     sizeOf (0 :: Int32))
                 ,indicesPtr
                 ,GL.StaticDraw)

drawSectorTextured :: Sector -> IO ()
drawSectorTextured Sector{..} =
  do activateMaterial sectorWallMaterial
     sectorDrawWalls
     activateMaterial sectorFloorMaterial
     sectorDrawFloor
     activateMaterial sectorCeilingMaterial
     sectorDrawCeiling
