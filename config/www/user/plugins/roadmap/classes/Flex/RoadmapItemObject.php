<?php
namespace Grav\Plugin\Roadmap\Flex;

use Grav\Common\Flex\Types\Generic\GenericObject;

/**
 * Roadmap item flex object. Stores `steps` as a YAML sequence on disk while
 * presenting the admin textarea field with a newline-delimited string, so the
 * form renderer's `|trim` filter doesn't blow up on an array value.
 */
class RoadmapItemObject extends GenericObject
{
    public function getFormValue($name, $default = null, $separator = null)
    {
        $value = parent::getFormValue($name, $default, $separator);

        if ($name === 'steps' && is_array($value)) {
            return implode("\n", array_map('strval', $value));
        }

        return $value;
    }

    protected function filterElements(array &$elements): void
    {
        if (array_key_exists('steps', $elements) && is_string($elements['steps'])) {
            $lines = preg_split('/\r?\n/', $elements['steps']) ?: [];
            $elements['steps'] = array_values(array_filter(
                array_map('trim', $lines),
                static fn ($line) => $line !== ''
            ));
        }

        parent::filterElements($elements);
    }
}
